# ENSNormalize.sol

[ENSIP-15](https://docs.ens.domains/ensip/15) label normalization in Solidity.
It implements `IENSIP15` (from [ensdomains/contracts-v2](https://github.com/ensdomains/contracts-v2)): `normalize(label)` returns the normalized label, or reverts `CannotNormalize(label)`.

The algorithm follows the reference implementation in [adraffy/ens-normalize-derive](https://github.com/adraffy/ens-normalize-derive) (`src/ensip15.ts`). The tables are derived from its spec files (`spec.json`, `nf.json`), and the tests are its `tests.json`.

- **Per label:** ENSIP-15 validates each label on its own, so there's no name splitting. `.` is a disallowed character, and `normalize("")` reverts: an empty label is invalid (only an empty *name* normalizes to `""`).
- **Only `normalize`:** no beautify, fragments, or tokenize. Error messages aren't reproduced: every failure is `CannotNormalize`.
- **Invalid UTF-8** (overlong, surrogates, truncated, > U+10FFFF) reverts.
- **Ownerless and immutable:** a new spec is a new deployment. The tables are code: the hot ones are in `ENSNormalize` itself (read with `CODECOPY`), the rest are in data contracts (read with `EXTCODECOPY`) whose codehashes are checked in the constructor.
- **`specHash()`** returns the sha256 of the `spec.json` it was built from (`spec_hash` in ens-normalize-derive's `tests.json`).

```solidity
import {IENSIP15} from "ENSNormalize.sol/src/IENSIP15.sol";
import {ENSNormalize} from "ENSNormalize.sol/src/ENSNormalize.sol";
import {ENSNormalizeDataDeployer} from "ENSNormalize.sol/src/generated/ENSNormalizeData.sol";

IENSIP15 ens = new ENSNormalize(ENSNormalizeDataDeployer.deploy());
ens.normalize("RaFFY"); // "raffy"
ens.normalize(unicode"🚴‍♂️"); // "🚴‍♂"
ens.normalize("a_b"); // reverts CannotNormalize("a_b")
```

## Commands

Requires [Foundry](https://getfoundry.sh) and [Bun](https://bun.sh).

```sh
bun install
bun run download   # data/spec.json, nf.json, tests.json from ens-normalize-derive (main)
bun run make       # data/*.json => src/generated/ENSNormalizeData.sol
forge test         # includes every test in data/tests.json
forge test --mc GasTest -vv   # gas report, writes snapshots/
```

`data/` is downloaded and gitignored. `src/generated/` and `snapshots/` (the gas report) are committed. CI regenerates the data and fails if it changes.

## Tests

- **tests.json:** `test/ENSNormalize.t.sol` runs every entry through `normalize()` as a forge test: each name is split on `.`, every label is normalized, and the result must equal `norm` (or `name`), or some label must revert when `error` is set.
  Forge's JSON cheatcodes coerce strings that look like numbers or hex and reject lone surrogates, so `test/TestsJSON.sol` is a small JSON parser for this file. A lone surrogate becomes U+FFFD, like `TextEncoder`.
  The tests are split into 8 shards so forge runs them in parallel (about 45s).
- **Every codepoint:** `test/Lookup.t.sol` hashes the contract's lookup of all 1,114,112 codepoints and compares it with the hash that `scripts/make.ts` computed from the spec.
- **Tables:** `test_tables` checks that the tables are where the contract reads them in its own code.

## Gas

From `forge test --mc GasTest -vv` (`snapshots/normalize.json`): the gas of the call itself, with every data contract cold (2600 for the first read of each, EIP-2929).

| label | gas | data contracts read |
|---|--:|---|
| `nick`, `vitalik-buterin` | 876 | |
| 40 hex characters | 1,097 | |
| `a` x 255 | 2,423 | |
| `RaFFY` | 1,708 | |
| `_dnslink` | 1,862 | |
| `💩` | 4,084 | |
| `🚴‍♂️` | 7,731 | |
| `1️⃣` | 5,544 | |
| `abc💩def` | 10,474 | |
| `café` | 6,058 | |
| `café123` | 9,349 | |
| `cafe` + U+0301 (NFC) | 15,334 | data0 |
| `日本語` | 6,324 | |
| `한국어` | 6,158 | |
| `привет` | 11,012 | data0 |
| `ελληνικά` | 12,901 | data0 |
| `عربي` | 9,227 | data0 |
| `नमस्ते` | 15,794 | data0 |
| `ＢＩＴＣＯＩＮ` | 24,247 | data0, data1 |

- **ASCII:** a label of only `a-z0-9-` is checked 32 bytes at a time and returned as-is. Other valid ascii and `A-Z` is one loop. Neither reads a table.
- **No data contract:** ascii and Latin-1, the buckets where most emoji start, Han, and Hangul are in `ENSNormalize`'s own code, with the class records, emoji, and group masks. A label of only those reads no other contract.
- **data0** has the other buckets, whole-script confusables, and NFC. **data1** has the mappings (only mapped characters read it).
- There's no length limit. Text costs about 830 per codepoint (`é` x 100 is 83,195), emoji about 2,000 (`💩` x 100 is 198,674), and text that isn't NFC about 5,000 per composition (`e` + U+0301 x 100 is 495,051).

Deploying is about 12.4M gas (`snapshots/deploy.json`): `ENSNormalizeData0` (4.9M), `ENSNormalizeData1` (2.2M), then `ENSNormalize` with their addresses (5.3M), each in its own transaction (under the EIP-7825 cap of 16.7M). `ENSNormalizeDataDeployer.deploy()` deploys the data contracts from a forge script.

## How it works

`normalize(label)`:

1. **ASCII Fast Path:** if every byte is `a-z0-9-`, check the label extension rule (`??--`) and return the label as-is. Else if every byte is valid ascii (`a-z0-9-_$`) or `A-Z`, lowercase it, and check the underscore and label extension rules.
2. **Classify:** decode UTF-8 and look up each codepoint, in one pass. While every codepoint is plain text (valid, and not an emoji start), the result is already the output: one text run. A digit is plain text unless FE0F or 20E3 follows (a keycap).
3. **Tokenize:** only if a codepoint wasn't plain text. At each codepoint, take the longest emoji (FE0F is optional where it appears in the fully-qualified form, and dropped from the output). Otherwise a codepoint is valid, mapped, ignored, or disallowed (revert). The codepoints inside an emoji aren't looked up.
4. **NFC:** each text run. A quick check (NFC_QC and canonical order) skips it for text that's already NFC. Otherwise: decompose, reorder, compose.
5. **Validate:** underscore only at the start; ascii labels can't have `--` at 3-4; a text run can't start with a combining mark; fenced characters can't be leading, trailing, or adjacent; the label's group is the highest priority group that contains every text codepoint; for groups without a CM whitelist, a CM's base must be primary in the group, and the NFD can't have duplicate or more than 4 consecutive non-spacing marks; whole-script confusables.
6. **Encode:** UTF-8. If nothing changed, the label is returned as-is.

Groups are bits of a `uint256` (171 groups), so group selection is an AND of each codepoint's mask, and the whole-script confusable check is a few ANDs:
the label is confusable if no codepoint is unique to one group, it has a confused codepoint, and some group is in every confused codepoint's complement (the groups of its whole outside its extent) and contains every other codepoint.

Steps 2-6 don't allocate: the context (caches), the codepoints, and the output entries are laid out from the free memory pointer, and the result is returned from assembly.

## Data layout

`scripts/make.ts` derives the tables, replays every lookup through the encoded bytes, and writes `src/generated/ENSNormalizeData.sol`: the constants, `TABLES`, and the data contracts (each starts with STOP).
Every table is random access, since the contract can't decode a compressed stream on every call.

`TABLES` (16,958 bytes) is a literal in `ENSNormalize`, returned by `tables()`. It's the only data in the contract's code, so solc puts it right before the metadata, and the contract reads it with `CODECOPY` at `codesize() - metadata - TABLES_SIZE`. Reading its own code has no account access cost (a data contract is 2600 for the first read, then 100).
That placement isn't guaranteed by the compiler: `test_tables` checks it, and it doesn't hold with via-IR.

| section | in | bytes | what |
|---|---|--:|---|
| DIRECT | tables | 512 | the value of each codepoint below 0x100 (ascii and Latin-1) |
| INDEX | tables | 2,042 | `cp >> 8` => offset of its bucket in RUNS, or `0x8000` + its offset in HOT (codepoints from `LIMIT` = 0x3FD00 up are disallowed, except the ignored E0100-E01EF) |
| HOT | tables | 1,868 | buckets, like RUNS: the most valid codepoints (of unrestricted groups) and emoji starts per byte, in what the other tables leave of `TABLES_BUDGET` |
| CLASSES | tables | 5,048 | 1,262 class records (u32): mask id, combining class rank, NFC_QC, CM, NSM, confused, unique, has decomposition, emoji node, valid, ignored, fenced, underscore |
| EMOJI | tables | 4,997 | emoji DAWG (227 nodes): `[terminal << 7 \| n][(cp: u24, node: u8) x n]` |
| MASKS | tables | 816 | mask id => (all groups, primary groups) |
| LISTS | tables | 1,675 | a group mask: a list of bit indices, or a bitmap when that's smaller |
| RUNS | data0 | 16,259 | buckets of 256 codepoints, identical ones are shared |
| CONF | data0 | 2,832 | for each confused class: its whole's groups and its extent's groups |
| DECOMP | data0 | 1,827 | canonical decompositions reachable from valid codepoints |
| COMP | data0 | 3,267 | compositions that can occur |
| MAP | data1 | 11,040 | mappings: linear (`cp + delta`), or a table of n codepoints of 2 or 3 bytes |

A value is a class id, or `0x8000` + an offset in MAP. A bucket gives the value of `lo = cp & 0xff`, in one of 3 formats:

| format | bytes | lookup | used for |
|---|---|---|---|
| tiny | `[2][value]([start - 1][value]) x 2` | up to 3 runs, compared in one word | Han, Hangul (39 buckets) |
| palette | `[1][index: 256][values]` | `values[index[lo]]` | dense scripts, when it's at most 128 bytes bigger than runs (28 buckets) |
| runs | `[0][n-1][sub: 8][values: n x u16][starts - 1: n-1]` | `sub[lo >> 5]` is the run that contains its 32-codepoint block, plus the number of the next 32 run starts that are `<= lo`, counted in one word with SWAR | the rest (103 buckets) |

The last bucket is cached in memory for the call (by its index entry, so buckets that share one aren't copied again), and 4 group masks.
A confused codepoint's class is also keyed by its whole, and those class ids are last, so CONF is indexed by `class id - CONF_CLASS`.

## Layout

| path | what |
|---|---|
| `src/ENSNormalize.sol` | the contract |
| `src/IENSIP15.sol` | interface, from contracts-v2 |
| `src/generated/ENSNormalizeData.sol` | **generated:** constants, `TABLES`, data contracts, `ENSNormalizeDataDeployer` |
| `scripts/make.ts` | spec => tables (`scripts/nf.ts`: NFC/NFD) |
| `scripts/download.ts` | fetches the spec and tests |
| `test/ENSNormalize.t.sol` | tests.json, examples |
| `test/Lookup.t.sol` | every codepoint's lookup |
| `test/Gas.t.sol` | gas report (`snapshots/`) |
