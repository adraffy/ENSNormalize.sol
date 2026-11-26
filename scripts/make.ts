// Derives the contract data from the ENSIP-15 spec files (data/spec.json + data/nf.json)
// and writes src/generated/ENSNormalizeData.sol: the data contracts and the layout constants.
//
// usage: bun scripts/make.ts
//
// Every table is random-access (the contract can't decode a compressed stream per call):
// a codepoint is looked up as INDEX[cp >> 8] => bucket of runs => run value => class record or mapping.
// See README.md "Data layout" and the readers in src/ENSNormalize.sol (they must match).

import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {NF, type NFJSON, isHangul, pairKey} from './nf.ts';
import {assert, Bytes, concat, hex, keccak256} from './utils.ts';

const ROOT = new URL('../', import.meta.url);
const OUT_SOL = new URL('src/generated/ENSNormalizeData.sol', ROOT);

type SpecJSON = {
	created: string;
	unicode: string;
	cldr: string;
	emoji: number[][];
	ignored: number[];
	mapped: [number, number[]][];
	fenced: [number, string][];
	wholes: {target: string; valid: number[]; confused: number[]}[];
	cm: number[];
	nsm: number[];
	nsm_max: number;
	groups: {name: string; primary: number[]; secondary?: number[]; cm?: number[]; restricted?: boolean}[];
};

const specBytes = readFileSync(new URL('data/spec.json', ROOT));
const nfBytes = readFileSync(new URL('data/nf.json', ROOT));
const spec: SpecJSON = JSON.parse(specBytes.toString());
const nf = new NF(JSON.parse(nfBytes.toString()) as NFJSON);


// ************************************************************
// layout constants (mirrored in src/ENSNormalize.sol)

const BUCKET_BITS = 8;
const BUCKET_SIZE = 1 << BUCKET_BITS;
const MAX_CONTRACT = 24576 - 1; // EIP-170, minus the leading STOP

// class record bits
const C_MASK = 0; // 8 bits: index into MASKS
const C_RANK = 8; // 6 bits: canonical combining class rank (0 = starter)
const C_QC = 1 << 14; // NFC_QC != Yes
const C_CM = 1 << 15;
const C_NSM = 1 << 16;
const C_CONFUSED = 1 << 17; // whole-script confusable: see CONF
const C_UNIQUE = 1 << 18; // in exactly one group and not confusable
const C_DECOMP = 1 << 19; // has a canonical decomposition: see DECOMP
const C_EMOJI = 20; // 6 bits: emoji DAWG node after this cp (0 = not an emoji start)
const C_VALID = 1 << 26;
const C_IGNORED = 1 << 27;
const C_FENCED = 1 << 28;

const RUN_MAPPED = 0x8000; // run value: mapped, low 15 bits = offset into MAP

const FE0F = 0xfe0f;

// ************************************************************
// groups

const groups = spec.groups;
assert(groups.length <= 256, 'groups fit in a uint256 mask');
const maskAll = new Map<number, bigint>();
const maskPri = new Map<number, bigint>();
groups.forEach((g, i) => {
	const bit = 1n << BigInt(i);
	for (const cp of g.primary) {
		maskAll.set(cp, (maskAll.get(cp) ?? 0n) | bit);
		maskPri.set(cp, (maskPri.get(cp) ?? 0n) | bit);
	}
	for (const cp of g.secondary ?? []) maskAll.set(cp, (maskAll.get(cp) ?? 0n) | bit);
});
let checkNSM = 0n;
groups.forEach((g, i) => {
	if (!Array.isArray(g.cm)) checkNSM |= 1n << BigInt(i);
});

const popcount = (x: bigint) => {
	let n = 0;
	for (; x; x &= x - 1n) n++;
	return n;
};
const maskBits = (x: bigint) => {
	const v: number[] = [];
	for (let i = 0; x; i++, x >>= 1n) if (x & 1n) v.push(i);
	return v;
};

// valid = union of the groups, closed under NFD
const valid = new Set(maskAll.keys());
for (const cp of [...valid]) for (const x of nf.decompose(cp)) valid.add(x);

const mapped = new Map(spec.mapped);
const ignored = new Set(spec.ignored);
const cm = new Set(spec.cm);
const nsm = new Set(spec.nsm);
const fenced = new Set(spec.fenced.map(([cp]) => cp));
for (const [cp, v] of mapped) {
	assert(!valid.has(cp) && !ignored.has(cp), `mapped ${hex(cp)} is also valid/ignored`);
	for (const x of v) assert(valid.has(x), `mapped ${hex(cp)} outputs non-valid ${hex(x)}`);
	assert(v.length > 0 && v.length <= 31, 'mapping length');
}
for (const cp of fenced) assert(valid.has(cp), `fenced ${hex(cp)} is valid`);
assert(spec.nsm_max === 4, 'nsm_max'); // hardcoded in the contract

// ************************************************************
// whole-script confusables
// for a confused cp: complement = union of its whole's extents - its own extent

const wholeValid = new Set(spec.wholes.flatMap((w) => w.valid));
const confused = new Map<number, {union: bigint; extent: bigint}>();
for (const w of spec.wholes) {
	const members = [...w.valid, ...w.confused].sort((a, b) => a - b);
	const extents: {groups: bigint; cps: number[]}[] = [];
	for (const cp of members) {
		const gs = maskAll.get(cp) ?? 0n;
		let ext = extents.find((x) => (x.groups & gs) !== 0n);
		if (!ext) extents.push((ext = {groups: 0n, cps: []}));
		ext.cps.push(cp);
		ext.groups |= gs;
	}
	const union = extents.reduce((a, x) => a | x.groups, 0n);
	for (const ext of extents) {
		for (const cp of ext.cps) {
			if (wholeValid.has(cp)) continue;
			assert(!confused.has(cp), `confused ${hex(cp)} in 2 wholes`);
			confused.set(cp, {union, extent: ext.groups});
		}
	}
}

// ************************************************************
// NF: decompositions reachable from valid cps (incl. composed intermediates that aren't valid)

const decompUsed = new Map<number, number[]>();
{
	const visit = (cp: number) => {
		const v = nf.decomp.get(cp);
		if (!v || decompUsed.has(cp)) return;
		assert(v.length === 2, `decomposition of ${hex(cp)} has 2 parts`);
		decompUsed.set(cp, v);
		v.forEach(visit);
	};
	for (const cp of valid) visit(cp);
}
for (const cp of decompUsed.keys()) {
	assert(!mapped.has(cp), `decomposable ${hex(cp)} isn't mapped`);
	assert(!isHangul(cp), 'hangul is algorithmic');
}
// compositions whose parts can occur: both parts fully decompose to valid cps
const compUsed: [number, number, number][] = [];
for (const [key, c] of nf.comp) {
	const a = Math.floor(key / 0x1000000);
	const b = key % 0x1000000;
	if (nf.decompose(c).every((x) => valid.has(x))) compUsed.push([a, b, c]);
}
compUsed.sort((x, y) => pairKey(x[0], x[1]) - pairKey(y[0], y[1]));

// ************************************************************
// emoji: trie (FE0F optional where it appears), minimized into a DAWG
// emoji output = matched input without FE0F, so nodes don't need to store the emoji

type TrieNode = {next: Map<number, TrieNode>; term: boolean};
const trieRoot: TrieNode = {next: new Map(), term: false};
for (const emoji of spec.emoji) {
	assert(!emoji.filter((cp) => cp !== FE0F).every((cp) => cp < 0x80), 'emoji has a non-ascii cp');
	let nodes = [trieRoot];
	for (const cp of emoji) {
		const next = nodes.map((node) => {
			let child = node.next.get(cp);
			if (!child) node.next.set(cp, (child = {next: new Map(), term: false}));
			return child;
		});
		if (cp === FE0F) nodes.push(...next);
		else nodes = next;
	}
	for (const node of nodes) node.term = true;
}
type DawgNode = {id: number; term: boolean; edges: [number, DawgNode][]};
const dawgNodes: DawgNode[] = [];
const dawgOf = new Map<TrieNode, DawgNode>();
{
	const registry = new Map<string, DawgNode>();
	const ids = new Map<DawgNode, number>();
	const minimize = (t: TrieNode): DawgNode => {
		let d = dawgOf.get(t);
		if (d) return d;
		const edges = [...t.next].sort((a, b) => a[0] - b[0]).map(([cp, c]) => [cp, minimize(c)] as [number, DawgNode]);
		const key = `${t.term ? 'T' : ''}${edges.map(([cp, c]) => `${cp}:${ids.get(c)}`).join(',')}`;
		d = registry.get(key);
		if (!d) {
			d = {id: 0, term: t.term, edges};
			registry.set(key, d);
			ids.set(d, registry.size);
		}
		dawgOf.set(t, d);
		return d;
	};
	for (const child of trieRoot.next.values()) minimize(child);
	// root children first, so the class record can hold them in 6 bits
	const order: DawgNode[] = [];
	const seen = new Set<DawgNode>();
	const add = (d: DawgNode) => {
		if (!seen.has(d)) {
			seen.add(d);
			order.push(d);
		}
	};
	for (const child of trieRoot.next.values()) add(dawgOf.get(child)!);
	const rootCount = order.length;
	for (let i = 0; i < order.length; i++) for (const [, c] of order[i]!.edges) add(c);
	order.forEach((d, i) => {
		d.id = i + 1;
		dawgNodes.push(d);
	});
	assert(rootCount < 64, 'emoji root children fit in 6 bits');
	assert(dawgNodes.length < 256, 'emoji nodes fit in a byte');
}
const emojiRoot = new Map<number, number>();
for (const [cp, t] of trieRoot.next) {
	assert(!mapped.has(cp), `emoji start ${hex(cp)} isn't mapped`);
	emojiRoot.set(cp, dawgOf.get(t)!.id);
}

// ************************************************************
// masks: (all, primary) per valid cp, stored as lists of group indices

const lists = new Bytes();
const listOffsets = new Map<bigint, number>();
function listOffset(mask: bigint): number {
	let off = listOffsets.get(mask);
	if (off === undefined) {
		const bits = maskBits(mask);
		off = lists.length;
		lists.u8(bits.length);
		for (const i of bits) lists.u8(i);
		listOffsets.set(mask, off);
	}
	return off;
}
const masks = new Bytes();
const maskIds = new Map<string, number>();
function maskId(all: bigint, pri: bigint): number {
	const key = `${all}/${pri}`;
	let id = maskIds.get(key);
	if (id === undefined) {
		id = maskIds.size;
		maskIds.set(key, id);
		masks.u16(listOffset(all));
		masks.u16(listOffset(pri));
	}
	return id;
}
maskId(0n, 0n); // 0 = no group

// ************************************************************
// class records

const LIMIT = (() => {
	let max = 0;
	for (const cp of [...valid, ...mapped.keys(), ...emojiRoot.keys(), ...decompUsed.keys()]) max = Math.max(max, cp);
	for (const cp of ignored) if (cp < 0xe0000) max = Math.max(max, cp);
	return (max >> BUCKET_BITS) + 1 << BUCKET_BITS;
})();
const IGNORED_HI = spec.ignored.filter((cp) => cp >= LIMIT);
assert(IGNORED_HI.every((cp, i) => cp === IGNORED_HI[0]! + i), 'ignored above LIMIT is one range');

function classRecord(cp: number): number {
	let r = 0;
	if (valid.has(cp)) {
		r |= C_VALID;
		const all = maskAll.get(cp) ?? 0n;
		r |= maskId(all, maskPri.get(cp) ?? 0n) << C_MASK;
		if (nf.qc.has(cp)) r |= C_QC;
		if (cm.has(cp)) r |= C_CM;
		if (nsm.has(cp)) r |= C_NSM;
		if (fenced.has(cp)) r |= C_FENCED;
		if (confused.has(cp)) r |= C_CONFUSED;
		else if (popcount(all) === 1) r |= C_UNIQUE;
	} else if (ignored.has(cp)) {
		r |= C_IGNORED;
	}
	if (valid.has(cp) || decompUsed.has(cp)) {
		const rank = nf.rank.get(cp) ?? 0;
		assert(rank < 64, 'rank fits in 6 bits');
		r |= rank << C_RANK;
	}
	if (decompUsed.has(cp)) r |= C_DECOMP;
	r |= (emojiRoot.get(cp) ?? 0) << C_EMOJI;
	return r >>> 0;
}

// ************************************************************
// mapping records
//   linear: [0x00][delta:i24]                     out = cp + delta
//   table:  [0x80 | w3 << 6 | n][base:u24][entries]  out = entry[cp - base], n cps of 2 or 3 bytes

const map = new Bytes();
const mapOf = new Map<number, number>(); // cp => offset
{
	const linear = new Map<number, number>();
	const linearOffset = (delta: number) => {
		let off = linear.get(delta);
		if (off === undefined) {
			off = map.length;
			map.u8(0).u24(delta & 0xffffff);
			linear.set(delta, off);
		}
		return off;
	};
	const keys = [...mapped.keys()].sort((a, b) => a - b);
	const single = (i: number) => mapped.get(keys[i]!)!.length === 1;
	const delta = (i: number) => mapped.get(keys[i]!)![0]! - keys[i]!;
	const linearRun = (i: number) => {
		let j = i + 1;
		if (single(i)) while (j < keys.length && keys[j] === keys[j - 1]! + 1 && single(j) && delta(j) === delta(i)) j++;
		return j - i;
	};
	for (let i = 0; i < keys.length; ) {
		const k = linearRun(i);
		const n = mapped.get(keys[i]!)!.length;
		let j = i + 1;
		if (k === 1) {
			while (j < keys.length && keys[j] === keys[j - 1]! + 1 && mapped.get(keys[j]!)!.length === n && linearRun(j) === 1) j++;
		}
		if (k > 1 || (j === i + 1 && n === 1)) {
			const off = linearOffset(delta(i));
			for (let x = i; x < i + k; x++) mapOf.set(keys[x]!, off);
			i += k;
		} else {
			const outs = keys.slice(i, j).map((cp) => mapped.get(cp)!);
			const w3 = outs.some((v) => v.some((cp) => cp > 0xffff));
			const off = map.length;
			map.u8(0x80 | (w3 ? 0x40 : 0) | n).u24(keys[i]!);
			for (const v of outs) for (const cp of v) w3 ? map.u24(cp) : map.u16(cp);
			for (let x = i; x < j; x++) mapOf.set(keys[x]!, off);
			i = j;
		}
	}
	assert(map.length < 0x8000, 'MAP offsets fit in 15 bits');
}

// ************************************************************
// runs: per bucket of 256 cps, sorted (start, value) runs; identical buckets are shared

const classes = new Bytes();
const classIds = new Map<number, number>();
function runValue(cp: number): number {
	const off = mapOf.get(cp);
	if (off !== undefined) return RUN_MAPPED | off;
	const rec = classRecord(cp);
	let id = classIds.get(rec);
	if (id === undefined) {
		id = classIds.size;
		classIds.set(rec, id);
		classes.u32(rec);
	}
	return id;
}
runValue(0x10ffff); // class 0 = disallowed
const index = new Bytes();
const runs = new Bytes();
let runCount = 0;
{
	const shared = new Map<string, number>();
	for (let b = 0; b < LIMIT >> BUCKET_BITS; b++) {
		const starts: number[] = [];
		const values: number[] = [];
		for (let i = 0; i < BUCKET_SIZE; i++) {
			const v = runValue((b << BUCKET_BITS) | i);
			if (!i || values[values.length - 1] !== v) {
				starts.push(i);
				values.push(v);
			}
		}
		const key = `${starts}/${values}`;
		let off = shared.get(key);
		if (off === undefined) {
			off = runs.length;
			runs.u8(starts.length - 1);
			for (const x of starts) runs.u8(x);
			for (const x of values) runs.u16(x);
			shared.set(key, off);
			runCount += starts.length;
		}
		index.u16(off);
	}
	assert(classIds.size < RUN_MAPPED, 'class ids fit in 15 bits');
	assert(maskIds.size <= 256, 'mask ids fit in a byte');
	assert(runs.length <= 0xffff, 'RUNS offsets fit in 16 bits');
}

// ************************************************************
// remaining tables

const emoji = new Bytes();
{
	const offsets: number[] = [];
	const body = new Bytes();
	for (const d of dawgNodes) {
		offsets.push(dawgNodes.length * 2 + body.length);
		assert(d.edges.length < 128, 'emoji fanout fits in 7 bits');
		body.u8((d.term ? 0x80 : 0) | d.edges.length);
		for (const [cp, c] of d.edges) body.u24(cp).u8(c.id);
	}
	for (const x of offsets) emoji.u16(x);
	emoji.bytes(body.toBytes());
}
const decomp = new Bytes();
for (const cp of [...decompUsed.keys()].sort((a, b) => a - b)) {
	const [a, b] = decompUsed.get(cp)!;
	decomp.u24(cp).u24(a!).u24(b!);
}
const comp = new Bytes();
for (const [a, b, c] of compUsed) comp.u24(a).u24(b).u24(c);
const conf = new Bytes();
{
	const cps = [...confused.keys()].filter((cp) => valid.has(cp)).sort((a, b) => a - b);
	for (const cp of cps) conf.u24(cp);
	for (const cp of cps) {
		const {union, extent} = confused.get(cp)!;
		conf.u16(listOffset(union)).u16(listOffset(extent));
	}
	assert(lists.length <= 0xffff, 'LISTS offsets fit in 16 bits');
	for (const mask of listOffsets.keys()) assert(popcount(mask) < 64, 'a list fits in 64 bytes');
}

// ************************************************************
// pack sections into data contracts (hot sections first)

const sections: {name: string; data: Uint8Array; count?: number}[] = [
	{name: 'INDEX', data: index.toBytes()},
	{name: 'RUNS', data: runs.toBytes()},
	{name: 'CLASSES', data: classes.toBytes()},
	{name: 'EMOJI', data: emoji.toBytes()},
	{name: 'MAP', data: map.toBytes()},
	{name: 'MASKS', data: masks.toBytes()},
	{name: 'LISTS', data: lists.toBytes()},
	{name: 'CONF', data: conf.toBytes(), count: conf.length / 7},
	{name: 'DECOMP', data: decomp.toBytes(), count: decomp.length / 9},
	{name: 'COMP', data: comp.toBytes(), count: comp.length / 9},
];
const contracts: {parts: Uint8Array[]; size: number}[] = [];
const placed = new Map<string, {contract: number; offset: number}>();
for (const s of sections) {
	assert(s.data.length <= MAX_CONTRACT, `${s.name} fits in a contract`);
	let i = contracts.findIndex((c) => c.size + s.data.length <= MAX_CONTRACT);
	if (i < 0) i = contracts.push({parts: [], size: 0}) - 1;
	const c = contracts[i]!;
	placed.set(s.name, {contract: i, offset: 1 + c.size}); // after the STOP
	c.parts.push(s.data);
	c.size += s.data.length;
}
const codes = contracts.map((c) => concat([Uint8Array.of(0), ...c.parts]));

// ************************************************************
// self-check: replay every lookup through the encoded tables, like the contract does

const views = new Map(sections.map((s) => [s.name, s.data]));
const view = (name: string) => views.get(name)!;
const rd = (b: Uint8Array, off: number, n: number) => {
	let x = 0;
	for (let i = 0; i < n; i++) x = x * 256 + b[off + i]!;
	return x;
};
function lookupRun(cp: number): number {
	if (cp >= LIMIT) return -1;
	const off = rd(view('INDEX'), (cp >> BUCKET_BITS) * 2, 2);
	const r = view('RUNS');
	const n = r[off]! + 1;
	const lo = cp & (BUCKET_SIZE - 1);
	let i = n - 1;
	while (r[off + 1 + i]! > lo) i--;
	return rd(r, off + 1 + n + i * 2, 2);
}
function readList(off: number): bigint {
	const l = view('LISTS');
	let m = 0n;
	for (let i = 0, n = l[off]!; i < n; i++) m |= 1n << BigInt(l[off + 1 + i]!);
	return m;
}
{
	for (let cp = 0; cp < 0x110000; cp++) {
		const v = lookupRun(cp);
		if (v < 0) {
			assert(!valid.has(cp) && !mapped.has(cp) && !emojiRoot.has(cp), `${hex(cp)} above LIMIT`);
			continue;
		}
		if (v & RUN_MAPPED) {
			const m = view('MAP');
			const off = v & ~RUN_MAPPED;
			const hdr = m[off]!;
			let out: number[];
			if (hdr & 0x80) {
				const n = hdr & 0x3f;
				const w = hdr & 0x40 ? 3 : 2;
				const pos = off + 4 + (cp - rd(m, off + 1, 3)) * n * w;
				out = Array.from({length: n}, (_, i) => rd(m, pos + i * w, w));
			} else {
				const d = rd(m, off + 1, 3);
				out = [cp + (d & 0x800000 ? d - 0x1000000 : d)];
			}
			assert(String(out) === String(mapped.get(cp)), `mapped ${hex(cp)}`);
		} else {
			assert(rd(view('CLASSES'), v * 4, 4) === classRecord(cp), `class ${hex(cp)}`);
		}
	}
	for (const [key, id] of maskIds) {
		const [all, pri] = key.split('/').map(BigInt);
		assert(readList(rd(view('MASKS'), id * 4, 2)) === all && readList(rd(view('MASKS'), id * 4 + 2, 2)) === pri, 'mask');
	}
	// every emoji matches through the DAWG, with and without FE0F
	const e = view('EMOJI');
	const step = (node: number, cp: number) => {
		const off = rd(e, (node - 1) * 2, 2);
		for (let i = 0, n = e[off]! & 0x7f; i < n; i++) {
			if (rd(e, off + 1 + i * 4, 3) === cp) return e[off + 4 + i * 4]!;
		}
		return 0;
	};
	const term = (node: number) => !!(e[rd(e, (node - 1) * 2, 2)]! & 0x80);
	for (const em of spec.emoji) {
		for (const v of [em, em.filter((cp) => cp !== FE0F)]) {
			let node = emojiRoot.get(v[0]!)!;
			for (const cp of v.slice(1)) node = step(node, cp);
			assert(node && term(node), `emoji ${v.map(hex)}`);
		}
	}
}

// ************************************************************
// output

const ASCII_VALID = [...Array(128).keys()].filter((cp) => valid.has(cp)).reduce((a, cp) => a | (1n << BigInt(cp)), 0n);
for (let cp = 0x41; cp <= 0x5a; cp++) assert(String(mapped.get(cp)) === String(cp + 32), 'A-Z => a-z');
for (const cp of [0x2d, 0x5f, ...Array(26).keys().map((i) => 0x61 + i)]) assert(valid.has(cp), 'ascii valid');
for (let cp = 0; cp < 0x80; cp++) assert(!ignored.has(cp), 'no ascii ignored');

// buffer bounds: an input cp becomes at most MAX_EXPAND cps (mapped, then NFD), a valid cp decomposes to at most MAX_DECOMP
const MAX_DECOMP = Math.max(...[...valid].map((cp) => nf.decompose(cp).length));
const MAX_EXPAND = Math.max(MAX_DECOMP, ...[...mapped.values()].map((v) => nf.nfd(v).length));

const u256 = (x: bigint) => `0x${x.toString(16).padStart(64, '0')}`;
const section = (name: string) => {
	const {contract, offset} = placed.get(name)!;
	return [
		`uint256 internal constant ${name}_DATA = ${contract};`,
		`uint256 internal constant ${name}_OFFSET = ${offset};`,
	];
};
const sol = `// SPDX-License-Identifier: MIT
// Generated by scripts/make.ts from ens-normalize-derive: do not edit.
pragma solidity ^0.8.24;

/// @dev Spec-derived constants for ENSNormalize.
library ENSNormalizeSpec {
    // spec.json created ${spec.created}
    // unicode ${spec.unicode}
    // cldr ${spec.cldr}

    uint256 internal constant DATA_COUNT = ${codes.length};

    /// @dev The codehash of each data contract.
    function dataHash(uint256 i) internal pure returns (bytes32) {
${codes.map((c, i) => `        if (i == ${i}) return ${keccak256(c)}; // ${c.length} bytes`).join('\n')}
        return 0;
    }

    /// @dev Sections: the data contract that holds it, and its byte offset there.
${sections.flatMap((s) => section(s.name).map((x) => `    ${x}`)).join('\n')}
    uint256 internal constant CONF_COUNT = ${conf.length / 7};
    uint256 internal constant DECOMP_COUNT = ${decomp.length / 9};
    uint256 internal constant COMP_COUNT = ${comp.length / 9};
    uint256 internal constant EMOJI_COUNT = ${dawgNodes.length};

    /// @dev Codepoints at or above LIMIT are disallowed, except IGNORED_LO..IGNORED_HI.
    uint256 internal constant LIMIT = 0x${hex(LIMIT)};
    uint256 internal constant IGNORED_LO = 0x${hex(IGNORED_HI[0]!)};
    uint256 internal constant IGNORED_HI = 0x${hex(IGNORED_HI[IGNORED_HI.length - 1]!)};

    /// @dev An input cp becomes at most MAX_EXPAND cps; a valid cp decomposes to at most MAX_DECOMP cps.
    uint256 internal constant MAX_EXPAND = ${MAX_EXPAND};
    uint256 internal constant MAX_DECOMP = ${MAX_DECOMP};

    /// @dev Bit i = ascii cp i is valid.
    uint256 internal constant ASCII_VALID = 0x${ASCII_VALID.toString(16)};
    /// @dev Bit i = group i is not CM-whitelisted (enforce NSM rules).
    uint256 internal constant CHECK_NSM = ${u256(checkNSM)};
}
${codes
	.map(
		(c, i) => `
/// @dev Raw data, deployed as code (starts with STOP).
contract ENSNormalizeData${i} {
    constructor() {
        bytes memory v =
            hex"${Buffer.from(c).toString('hex')}";
        assembly {
            return(add(v, 32), mload(v))
        }
    }
}
`,
	)
	.join('')}
/// @dev Deploys the data contracts (each in its own transaction when broadcast).
library ENSNormalizeDataDeployer {
    function deploy() internal returns (address[] memory data) {
        data = new address[](${codes.length});
${codes.map((_, i) => `        data[${i}] = address(new ENSNormalizeData${i}());`).join('\n')}
    }
}
`;
mkdirSync(new URL('.', OUT_SOL), {recursive: true});
writeFileSync(OUT_SOL, sol);

console.log(`unicode ${spec.unicode}`);
console.log(`valid ${valid.size}, mapped ${mapped.size}, ignored ${ignored.size}, groups ${groups.length}`);
console.log(`classes ${classIds.size}, runs ${runCount}, masks ${maskIds.size}, lists ${listOffsets.size}`);
console.log(`emoji ${spec.emoji.length} => ${dawgNodes.length} nodes; confused ${conf.length / 7}; decomp ${decomp.length / 9}; comp ${comp.length / 9}`);
for (const s of sections) {
	const p = placed.get(s.name)!;
	console.log(`${s.name.padEnd(8)} ${String(s.data.length).padStart(6)}  data${p.contract}+${p.offset}`);
}
console.log(`total ${codes.reduce((a, c) => a + c.length, 0)} bytes in ${codes.length} contracts: ${codes.map((c) => c.length).join(', ')}`);
