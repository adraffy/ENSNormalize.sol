// Derives the contract data from the ENSIP-15 spec files (data/spec.json + data/nf.json)
// and writes src/generated/ENSNormalizeData.sol: the tables and the layout constants.
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
const SUB_SIZE = 32; // cps per sub-index entry: a word of starts
const SUB_COUNT = BUCKET_SIZE / SUB_SIZE;
const DIRECT_LIMIT = 0x100; // cps below this are looked up directly
const BUCKET_RUNS = 0;
const BUCKET_PALETTE = 1;
const BUCKET_TINY = 2;
const TINY_RUNS = 3;
const PALETTE_SLACK = 128; // a palette bucket can be this many bytes bigger than its runs
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
const C_UNDERSCORE = 1 << 29; // the underscore: its rule is only checked if there is one

const RUN_MAPPED = 0x8000; // run value: mapped, low 15 bits = offset into MAP
const INDEX_HOT = 0x8000; // index entry: the bucket is in HOT (the contract's code), not RUNS
// the tables in the contract's code can't exceed this: EIP-170 (24576) minus the contract's logic
// the hot buckets fill what the other tables leave
const TABLES_BUDGET = 16960;
const HOT_EMOJI_WEIGHT = 512; // a hot bucket is ranked by its valid cps, and an emoji start counts as 2 buckets of them

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
// compositions that can occur: a starter + a char, that fully decompose to valid cps
const compUsed: [number, number, number][] = [];
for (const [key, c] of nf.comp) {
	const a = Math.floor(key / 0x1000000);
	const b = key % 0x1000000;
	if (nf.rank.has(a)) continue; // only a starter composes
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
	// the contract only tries an emoji at an ascii cp (a digit) if FE0F or 20E3 follows
	assert(emoji[0]! >= 0x80 || emoji[1] === FE0F || emoji[1] === 0x20e3, 'an ascii emoji start is a keycap');
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
// masks: (all, primary) per valid cp

// a mask is [n][bit indices: n], or [0xff][bitmap: GROUP_BYTES] when that's smaller
const GROUP_BYTES = Math.ceil(groups.length / 8);
const lists = new Bytes();
const listOffsets = new Map<bigint, number>();
function listOffset(mask: bigint): number {
	let off = listOffsets.get(mask);
	if (off === undefined) {
		const bits = maskBits(mask);
		off = lists.length;
		if (bits.length > GROUP_BYTES) {
			lists.u8(0xff);
			for (let i = GROUP_BYTES - 1; i >= 0; i--) lists.u8(Number((mask >> BigInt(8 * i)) & 0xffn));
		} else {
			lists.u8(bits.length);
			for (const i of bits) lists.u8(i);
		}
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
		if (cp === 0x5f) r |= C_UNDERSCORE;
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
			assert(n * (w3 ? 3 : 2) <= 32, 'a mapping is read as one word');
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
// a bucket is one of:
//   tiny:    [2][value]([start - 1][value]) x 2    up to 3 runs (eg. Han, Hangul), unused starts are 0xff
//   palette: [1][index: 256][values]   values[index[lo]]: when that's not much bigger than runs (dense scripts)
//   runs:    [0][n - 1][sub: 8][values: 2n][starts - 1: n - 1]
//            sub[k] = the run that contains cp 32k of the bucket, and the first start (0) isn't stored

// a confused cp's class is also keyed by its whole, and those classes are numbered last:
// CONF[class id - CONF_CLASS] is its (union, extent)
const classes = new Bytes();
const conf = new Bytes();
const classIds = new Map<string, number>();
const classKey = (cp: number) => {
	const rec = classRecord(cp);
	const c = rec & C_CONFUSED ? confused.get(cp)! : undefined;
	return c ? `${rec}/${c.union}/${c.extent}` : `${rec}`;
};
let CONF_CLASS = 0;
{
	const plain = new Set<string>([classKey(0x10ffff)]); // class 0 = disallowed
	const whole = new Map<string, number>();
	for (let cp = 0; cp < LIMIT; cp++) {
		if (mapOf.has(cp)) continue;
		const key = classKey(cp);
		if (key.includes('/')) whole.set(key, cp);
		else plain.add(key);
	}
	for (const key of plain) {
		classIds.set(key, classIds.size);
		classes.u32(Number(key));
	}
	CONF_CLASS = classIds.size;
	for (const [key, cp] of whole) {
		classIds.set(key, classIds.size);
		classes.u32(classRecord(cp));
		const {union, extent} = confused.get(cp)!;
		conf.u16(listOffset(union)).u16(listOffset(extent));
	}
}
function runValue(cp: number): number {
	const off = mapOf.get(cp);
	return off === undefined ? classIds.get(classKey(cp))! : RUN_MAPPED | off;
}
runValue(0x10ffff); // class 0 = disallowed
// cps below DIRECT_LIMIT (ascii and Latin-1) have their own table of values, in the contract's code
// hot buckets go there too, so a label of only those reads no data contract:
// the buckets with the most valid cps (of unrestricted groups) and emoji starts per byte (Han and Hangul are a few bytes)
const unrestricted = groups.reduce((a, g, i) => (g.restricted ? a : a | (1n << BigInt(i))), 0n);
const index = new Bytes();
const runs = new Bytes();
const hot = new Bytes();
const buckets: {key: string; bytes: Uint8Array; score: number}[] = [];
let hotBuckets = ''; // for the log: the best buckets (and how many share it), ! = didn't fit
let runCount = 0;
let maxBucket = 0;
const direct = new Bytes();
for (let cp = 0; cp < DIRECT_LIMIT; cp++) direct.u16(runValue(cp));
for (let b = DIRECT_LIMIT >> BUCKET_BITS; b < LIMIT >> BUCKET_BITS; b++) {
	const starts: number[] = [];
	const values: number[] = [];
	let score = 0;
	for (let i = 0; i < BUCKET_SIZE; i++) {
		const cp = (b << BUCKET_BITS) | i;
		const v = runValue(cp);
		if (!i || values[values.length - 1] !== v) {
			starts.push(i);
			values.push(v);
		}
		if ((maskAll.get(cp) ?? 0n) & unrestricted) score++;
		if (emojiRoot.has(cp)) score += HOT_EMOJI_WEIGHT;
	}
	const bytes = new Bytes();
	const palette = [...new Set(values)];
	const paletteSize = 1 + BUCKET_SIZE + 2 * palette.length;
	const runsSize = 1 + SUB_COUNT + 3 * starts.length;
	if (starts.length <= TINY_RUNS) {
		bytes.u8(BUCKET_TINY).u16(values[0]!);
		for (let i = 1; i < TINY_RUNS; i++) bytes.u8(i < starts.length ? starts[i]! - 1 : 0xff).u16(values[i] ?? 0);
	} else if (paletteSize <= runsSize + PALETTE_SLACK) {
		bytes.u8(BUCKET_PALETTE);
		starts.forEach((x, i) => {
			for (const end = starts[i + 1] ?? BUCKET_SIZE; x < end; x++) bytes.u8(palette.indexOf(values[i]!));
		});
		for (const x of palette) bytes.u16(x);
	} else {
		bytes.u8(BUCKET_RUNS).u8(starts.length - 1);
		for (let k = 0; k < BUCKET_SIZE; k += SUB_SIZE) bytes.u8(starts.findLastIndex((x) => x <= k));
		for (const x of values) bytes.u16(x);
		for (const x of starts.slice(1)) bytes.u8(x - 1);
	}
	buckets.push({key: `${starts}/${values}`, bytes: bytes.toBytes(), score});
	maxBucket = Math.max(maxBucket, bytes.length);
}
// the hot buckets are chosen after the other tables are built: see fillBuckets()
function fillBuckets(budget: number) {
	const scores = new Map<string, {bytes: Uint8Array; score: number}>(); // identical buckets are shared
	for (const {key, bytes, score} of buckets) {
		const x = scores.get(key);
		if (x) x.score += score;
		else scores.set(key, {bytes, score});
	}
	const offsets = new Map<string, number>();
	const ranked: string[] = [];
	for (const [key, {bytes}] of [...scores].sort((a, b) => b[1].score / b[1].bytes.length - a[1].score / a[1].bytes.length)) {
		const fits = hot.length + bytes.length <= budget;
		if (ranked.length < 48) {
			const v = buckets.flatMap((x, i) => (x.key === key ? [(i + (DIRECT_LIMIT >> BUCKET_BITS)).toString(16)] : []));
			ranked.push(`${fits ? '' : '!'}${v[0]}${v.length > 1 ? `x${v.length}` : ''}`);
		}
		if (!fits) continue;
		offsets.set(key, INDEX_HOT | hot.length);
		hot.bytes(bytes);
	}
	hotBuckets = ranked.join(' ');
	for (let b = 0; b < DIRECT_LIMIT >> BUCKET_BITS; b++) index.u16(0); // unused
	for (const {key, bytes} of buckets) {
		let off = offsets.get(key);
		if (off === undefined) {
			offsets.set(key, (off = runs.length));
			runs.bytes(bytes);
		}
		index.u16(off);
	}
	runCount = [...offsets.keys()].reduce((a, key) => a + key.split('/')[0]!.split(',').length, 0);
	assert(runs.length < INDEX_HOT, 'RUNS offsets fit in 15 bits');
}
assert(classIds.size < RUN_MAPPED, 'class ids fit in 15 bits');
assert(maskIds.size <= 256, 'mask ids fit in a byte');

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
assert(lists.length <= 0xffff, 'LISTS offsets fit in 16 bits');
// compositions are only tried for a second char with NFC_QC != Yes
for (const [, b] of compUsed) assert(nf.qc.has(b), `composing ${hex(b)} has NFC_QC != Yes`);
for (let cp = 0x1161; cp < 0x11c3; cp++) {
	if (valid.has(cp) && (cp < 0x1176 || cp > 0x11a7)) assert(nf.qc.has(cp), `jamo ${hex(cp)} has NFC_QC != Yes`);
}

// ************************************************************
// the hot tables go in ENSNormalize's own code (CODECOPY: no account access)
// the rest is packed into data contracts (EXTCODECOPY), most used first

fillBuckets(TABLES_BUDGET - (2 * (LIMIT >> BUCKET_BITS) + direct.length + classes.length + emoji.length + masks.length + lists.length));
const IGNORED_CLASS = classIds.get(String(C_IGNORED))!; // ignored, and nothing else
assert(IGNORED_CLASS, 'there is a plain ignored class');

type Section = {name: string; data: Uint8Array};
const tableSections: Section[] = [
	{name: 'DIRECT', data: direct.toBytes()},
	{name: 'INDEX', data: index.toBytes()},
	{name: 'HOT', data: hot.toBytes()},
	{name: 'CLASSES', data: classes.toBytes()},
	{name: 'EMOJI', data: emoji.toBytes()},
	{name: 'MASKS', data: masks.toBytes()},
	{name: 'LISTS', data: lists.toBytes()},
];
const dataSections: Section[] = [
	{name: 'RUNS', data: runs.toBytes()},
	{name: 'CONF', data: conf.toBytes()},
	{name: 'DECOMP', data: decomp.toBytes()},
	{name: 'COMP', data: comp.toBytes()},
	{name: 'MAP', data: map.toBytes()},
];
const sections = [...tableSections, ...dataSections];
const placed = new Map<string, {contract: number; offset: number}>(); // contract -1 = tables
let tablesSize = 0;
for (const s of tableSections) {
	placed.set(s.name, {contract: -1, offset: tablesSize});
	tablesSize += s.data.length;
}
const tables = concat(tableSections.map((s) => s.data));
const contracts: {parts: Uint8Array[]; size: number}[] = [];
for (const s of dataSections) {
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
	if (cp < DIRECT_LIMIT) return rd(view('DIRECT'), cp * 2, 2);
	let off = rd(view('INDEX'), (cp >> BUCKET_BITS) * 2, 2);
	const r = view(off & INDEX_HOT ? 'HOT' : 'RUNS');
	off &= ~INDEX_HOT;
	const lo = cp & (BUCKET_SIZE - 1);
	const format = r[off++]!;
	if (format === BUCKET_TINY) {
		let v = rd(r, off, 2);
		for (let i = 1; i < TINY_RUNS; i++) if (lo > r[off + 3 * i - 1]!) v = rd(r, off + 3 * i, 2);
		return v;
	}
	if (format === BUCKET_PALETTE) return rd(r, off + BUCKET_SIZE + 2 * r[off + lo]!, 2);
	const n = r[off]! + 1;
	const values = off + 1 + SUB_COUNT;
	const starts = values + 2 * n; // starts[i] is of run i + 1, minus 1
	// the run that contains the sub-block, plus the next 32 starts that are <= lo
	let i = r[off + 1 + Math.floor(lo / SUB_SIZE)]!;
	for (let j = 0; j < SUB_SIZE && i + 1 < n && r[starts + i]! < lo; j++) i++;
	return rd(r, values + i * 2, 2);
}
const lookups: number[] = [];
function readList(off: number): bigint {
	const l = view('LISTS');
	let m = 0n;
	if (l[off] === 0xff) {
		for (let i = 0; i < GROUP_BYTES; i++) m = (m << 8n) | BigInt(l[off + 1 + i]!);
	} else {
		for (let i = 0, n = l[off]!; i < n; i++) m |= 1n << BigInt(l[off + 1 + i]!);
	}
	return m;
}
{
	for (let cp = 0; cp < 0x110000; cp++) {
		const v = lookupRun(cp);
		// what the contract's _lookup() returns: test/Lookup.t.sol checks every cp against LOOKUP_HASH
		lookups.push(
			v < 0
				? ignored.has(cp)
					? C_IGNORED + IGNORED_CLASS * 2 ** 32
					: 0
				: v & RUN_MAPPED
					? 0x80000000 + (v & ~RUN_MAPPED)
					: rd(view('CLASSES'), v * 4, 4) + v * 2 ** 32,
		);
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
			const c = valid.has(cp) && confused.get(cp);
			assert(!c === v < CONF_CLASS, `confused class ${hex(cp)}`);
			if (c) {
				const at = (v - CONF_CLASS) * 4;
				assert(readList(rd(view('CONF'), at, 2)) === c.union && readList(rd(view('CONF'), at + 2, 2)) === c.extent, `whole ${hex(cp)}`);
			}
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
// the contract's ascii fast path: a-z 0-9 and hyphen are valid
for (const cp of [0x2d, 0x5f, ...Array(26).keys().map((i) => 0x61 + i), ...Array(10).keys().map((i) => 0x30 + i)]) {
	assert(valid.has(cp), 'ascii valid');
}
for (let cp = 0; cp < 0x80; cp++) assert(!ignored.has(cp), 'no ascii ignored');

let lookupHash = `0x${'0'.repeat(64)}`;
for (let i = 0; i < lookups.length; i += 256) {
	const chunk = new Bytes().bytes(Buffer.from(lookupHash.slice(2), 'hex'));
	for (const x of lookups.slice(i, i + 256)) chunk.bytes(new Uint8Array(26)).u24(Math.floor(x / 2 ** 24)).u24(x % 2 ** 24);
	lookupHash = keccak256(chunk.toBytes());
}

const u256 = (x: bigint) => `0x${x.toString(16).padStart(64, '0')}`;
const section = ({name}: Section) => {
	const {contract, offset} = placed.get(name)!;
	return contract < 0
		? [`uint256 constant ${name}_OFFSET = ${offset};`]
		: [`uint256 constant ${name}_DATA = ${contract};`, `uint256 constant ${name}_OFFSET = ${offset};`];
};
const emojiNodeSize = 1 + 4 * Math.max(...dawgNodes.map((d) => d.edges.length));
const sol = `// SPDX-License-Identifier: MIT
// Generated by scripts/make.ts from ens-normalize-derive: do not edit.
pragma solidity ^0.8.24;

// spec.json created ${spec.created}
// unicode ${spec.unicode}
// cldr ${spec.cldr}

/// @dev sha256(spec.json)
bytes32 constant SPEC_HASH = 0x${new Bun.CryptoHasher('sha256').update(specBytes).digest('hex')};

/// @dev Codepoints at or above LIMIT are disallowed, except IGNORED_LO..IGNORED_HI (class IGNORED_CLASS).
uint256 constant LIMIT = 0x${hex(LIMIT)};
uint256 constant IGNORED_CLASS = ${IGNORED_CLASS};
uint256 constant IGNORED_LO = 0x${hex(IGNORED_HI[0]!)};
uint256 constant IGNORED_HI = 0x${hex(IGNORED_HI[IGNORED_HI.length - 1]!)};

/// @dev Bit i = ascii cp i is valid.
uint256 constant ASCII_VALID = 0x${ASCII_VALID.toString(16)};
/// @dev Bit i = group i is not CM-whitelisted (enforce NSM rules).
uint256 constant CHECK_NSM = ${u256(checkNSM)};

/// @dev Tables in ENSNormalize's own code: byte offsets in TABLES.
${tableSections.flatMap(section).join('\n')}
/// @dev Tables in the data contracts: the contract, and the byte offset in its code.
${dataSections.flatMap(section).join('\n')}
uint256 constant DECOMP_COUNT = ${decomp.length / 9};
uint256 constant COMP_COUNT = ${comp.length / 9};
/// @dev Class ids from CONF_CLASS are confused: CONF[id - CONF_CLASS].
uint256 constant CONF_CLASS = ${CONF_CLASS};
/// @dev The most bytes of a bucket in RUNS, and of a node in EMOJI.
uint256 constant BUCKET_SIZE = ${maxBucket};
uint256 constant EMOJI_NODE_SIZE = ${emojiNodeSize};
/// @dev A bitmap in LISTS is its top bytes: shift right by this.
uint256 constant LIST_BITMAP_SHIFT = ${256 - 8 * GROUP_BYTES};

uint256 constant DATA_COUNT = ${codes.length};

/// @dev The codehash of each data contract.
function dataHash(uint256 i) pure returns (bytes32) {
${codes.map((c, i) => `    if (i == ${i}) return ${keccak256(c)}; // ${c.length} bytes`).join('\n')}
    return 0;
}

/// @dev keccak256 chain of _lookup() of every codepoint, 256 at a time (as uint256).
bytes32 constant LOOKUP_HASH = ${lookupHash};

uint256 constant TABLES_SIZE = ${tables.length};
bytes32 constant TABLES_HASH = ${keccak256(tables)};
bytes constant TABLES =
    hex"${Buffer.from(tables).toString('hex')}";
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
console.log(`classes ${classIds.size} (${classIds.size - CONF_CLASS} confused), runs ${runCount}, masks ${maskIds.size}, lists ${listOffsets.size}`);
console.log(`emoji ${spec.emoji.length} => ${dawgNodes.length} nodes; decomp ${decomp.length / 9}; comp ${comp.length / 9}`);
for (const s of sections) {
	const p = placed.get(s.name)!;
	console.log(`${s.name.padEnd(8)} ${String(s.data.length).padStart(6)}  ${p.contract < 0 ? 'tables' : `data${p.contract}`}+${p.offset}`);
}
console.log(`tables ${tables.length} bytes (in ENSNormalize)`);
console.log(`hot buckets: ${hotBuckets}`);
{
	const fmt = (b: number) => 'RPT'[buckets[b - (DIRECT_LIMIT >> BUCKET_BITS)]!.bytes[0]!];
	const unique = new Map(buckets.map((x) => [x.key, x.bytes[0]!]));
	const count = (f: number) => [...unique.values()].filter((x) => x === f).length;
	console.log(`buckets: ${count(BUCKET_TINY)} tiny, ${count(BUCKET_PALETTE)} palette, ${count(BUCKET_RUNS)} runs (max ${maxBucket} bytes)`);
	console.log(`formats: ${[1, 2, 3, 4, 5, 6, 7, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 0x10, 0x1e, 0x1f, 0x20, 0x21, 0x30, 0x4e, 0xac, 0xff, 0x1f4].map((b) => `${b.toString(16)}:${fmt(b)}`).join(' ')}`);
}
console.log(`data ${codes.reduce((a, c) => a + c.length, 0)} bytes in ${codes.length} contracts: ${codes.map((c) => c.length).join(', ')}`);
