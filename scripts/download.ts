// Fetches the spec and tests from adraffy/ens-normalize-derive into data/.
//
// usage:
//   bun scripts/download.ts          # fetch missing files
//   bun scripts/download.ts --force  # refetch everything
//
// DERIVE is a branch (or commit) of ens-normalize-derive.

import {existsSync, mkdirSync} from 'node:fs';

const DERIVE = 'main';
const BASE = `https://raw.githubusercontent.com/adraffy/ens-normalize-derive/${DERIVE}/output/`;
const FILES = ['spec.json', 'nf.json', 'tests.json'];
const DIR = new URL('../data/', import.meta.url);

const force = process.argv.includes('--force');
mkdirSync(DIR, {recursive: true});
await Promise.all(
	FILES.map(async (name) => {
		const file = new URL(name, DIR);
		if (!force && existsSync(file)) return;
		const res = await fetch(BASE + name);
		if (!res.ok) throw new Error(`download failed: ${name}: ${res.status}`);
		const bytes = await res.bytes();
		JSON.parse(new TextDecoder().decode(bytes)); // sanity check
		await Bun.write(file, bytes);
		console.log(`downloaded ${name} (${bytes.length} bytes)`);
	}),
);
