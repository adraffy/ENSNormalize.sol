// Prepares the exhaustive comparison of ENSNormalize against the reference implementation:
// every known ENS label (adraffy/ens-labels) through ens-normalize-derive's src/ensip15.ts.
//
// usage:
//   bun scripts/labels.ts            # fetch what's missing, write data/labels/
//   bun scripts/labels.ts --force    # refetch labels.json and the reference implementation
//   FOUNDRY_PROFILE=exhaustive forge test
//
// Downloads (into data/, gitignored):
//   labels.json         every known ENS label (about 50 MB)
//   derive/src/*.ts     the reference implementation (it only needs these 3 files: its other imports are types)
//
// Writes data/labels/: the spec hash, and SHARDS files of records
//   [kind: u8][label length: u32][label]                 kind 0: invalid, 1: normalized is the label
//   [2][label length: u32][label][norm length: u32][norm]  kind 2: normalized is different
// The labels are UTF-8 (a lone surrogate becomes U+FFFD, like TextEncoder).

import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';

const SHARDS = 32; // must match labels/Labels.t.sol
const LABELS_URL = 'https://raw.githubusercontent.com/adraffy/ens-labels/master/labels.json';
const DERIVE_URL = 'https://raw.githubusercontent.com/adraffy/ens-normalize-derive/main/src/';
const DERIVE_FILES = ['ensip15.ts', 'nf.ts', 'utils.ts'];

const ROOT = new URL('../', import.meta.url);
const DATA = new URL('data/', ROOT);
const DERIVE = new URL('derive/src/', DATA);
const OUT = new URL('labels/', DATA);
const force = process.argv.includes('--force');

async function download(url: string, file: URL) {
	if (!force && existsSync(file)) return;
	const res = await fetch(url);
	if (!res.ok) throw new Error(`download failed: ${url}: ${res.status}`);
	const bytes = await res.bytes();
	await Bun.write(file, bytes);
	console.log(`downloaded ${url} (${bytes.length} bytes)`);
}

mkdirSync(DERIVE, {recursive: true});
await Promise.all([
	download(LABELS_URL, new URL('labels.json', DATA)),
	...DERIVE_FILES.map((name) => download(DERIVE_URL + name, new URL(name, DERIVE))),
]);

// the reference must use the spec the contract was built from
const specBytes = readFileSync(new URL('spec.json', DATA));
const specHash = `0x${createHash('sha256').update(specBytes).digest('hex')}`;
const generated = readFileSync(new URL('src/generated/ENSNormalizeData.sol', ROOT), 'utf8');
const built = generated.match(/SPEC_HASH = (0x[0-9a-f]{64})/)?.[1];
if (built !== specHash) {
	throw new Error(`data/spec.json (${specHash}) isn't the spec of src/generated (${built}): run bun run make`);
}

const {ENSIP15} = await import(new URL('ensip15.ts', DERIVE).href);
const ref = new ENSIP15(JSON.parse(specBytes.toString()), JSON.parse(readFileSync(new URL('nf.json', DATA), 'utf8')));

// normalize() of one label: "." is disallowed and "" is an empty label (ENSIP-15 per label)
function expected(label: string): string | undefined {
	if (!label || label.includes('.')) return;
	const [info] = ref.split(label);
	if (info.error) return;
	return String.fromCodePoint(...info.output);
}

const labels: string[] = JSON.parse(readFileSync(new URL('labels.json', DATA), 'utf8'));
console.log(`labels: ${labels.length}`);

const encoder = new TextEncoder();
const shards: number[][] = Array.from({length: SHARDS}, () => []);
const counts = [0, 0, 0];
const t0 = performance.now();
labels.forEach((label, i) => {
	const norm = expected(label);
	const v = shards[i % SHARDS]!;
	const bytes = encoder.encode(label);
	const kind = norm === undefined ? 0 : norm === label ? 1 : 2;
	counts[kind]!++;
	v.push(kind);
	u32(v, bytes.length);
	for (const b of bytes) v.push(b);
	if (kind === 2) {
		const out = encoder.encode(norm);
		u32(v, out.length);
		for (const b of out) v.push(b);
	}
	if (i % 500000 === 0 && i) console.log(`  ${i} (${((performance.now() - t0) / 1000).toFixed(1)}s)`);
});
console.log(`invalid ${counts[0]}, normalized ${counts[1]}, changed ${counts[2]} (${((performance.now() - t0) / 1000).toFixed(1)}s)`);

mkdirSync(OUT, {recursive: true});
writeFileSync(new URL('spec_hash.txt', OUT), specHash);
shards.forEach((v, i) => writeFileSync(new URL(`${i}.bin`, OUT), Uint8Array.from(v)));
console.log(`wrote ${SHARDS} shards to data/labels/`);

function u32(v: number[], x: number) {
	v.push(x >>> 24, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
}
