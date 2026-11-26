# ENSNormalize.sol

[ENSIP-15](https://docs.ens.domains/ensip/15) label normalization in Solidity.
It implements `IENSIP15` (from [ensdomains/contracts-v2](https://github.com/ensdomains/contracts-v2)): `normalize(label)` returns the normalized label, or reverts `CannotNormalize(label)`.

The algorithm follows the reference implementation in [adraffy/ens-normalize-derive](https://github.com/adraffy/ens-normalize-derive) (`src/ensip15.ts`). The tables are derived from its spec files (`spec.json`, `nf.json`), and the tests are its `tests.json`.

- **Per label:** ENSIP-15 validates each label on its own, so there's no name splitting. `.` is a disallowed character, and `normalize("")` reverts: an empty label is invalid (only an empty *name* normalizes to `""`).
- **Only `normalize`:** no beautify, fragments, or tokenize. Error messages aren't reproduced: every failure is `CannotNormalize`.
- **Invalid UTF-8** (overlong, surrogates, truncated, > U+10FFFF) reverts.
- **Ownerless and immutable:** a new spec is a new deployment. The tables are deployed as code in data contracts (read with `EXTCODECOPY`), and `ENSNormalize` checks each one's codehash in its constructor.
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
forge test --mc GasTest -vv   # gas report
```

`data/` is downloaded and gitignored. `src/generated/` is committed. CI regenerates it and fails if it changes.

## Tests

`test/ENSNormalize.t.sol` runs every entry of `tests.json` through `normalize()` as a forge test: each name is split on `.`, every label is normalized, and the result must equal `norm` (or `name`), or some label must revert when `error` is set.
Forge's JSON cheatcodes coerce strings that look like numbers or hex and reject lone surrogates, so `test/TestsJSON.sol` is a small JSON parser for this file. A lone surrogate becomes U+FFFD, like `TextEncoder`.
The tests are split into 8 shards so forge runs them in parallel (about 40s).

## Gas

From `forge test --mc GasTest -vv`, with warm data contracts. A first call in a transaction pays 2600 more for each data contract it reads (EIP-2929). Labels of only valid ascii and A-Z never read them.

| label | gas |
|---|--:|
| `nick` | 7,162 |
| `vitalik-buterin` | 9,338 |
| `café` | 24,481 |
| `cafe` + U+0301 (NFC) | 45,434 |
| `💩` | 16,949 |
| `🚴‍♂️` | 22,188 |
| `ＢＩＴＣＯＩＮ` | 36,596 |
| `привет` | 26,968 |
| `日本語` | 22,400 |
| `नमस्ते` | 36,050 |

There's no length limit, but memory grows with the label (about 6 words per codepoint, and EVM memory cost is quadratic), so gas grows faster than linearly. From `forge test --mc LongTest -vv`:

| label | bytes | gas |
|---|--:|--:|
| `a` x 256 | 256 | 46,588 |
| `é` x 256 | 512 | 697,711 |
| `💩` x 256 | 1,024 | 942,123 |
| `e` + U+0301 x 256 (NFC) | 768 | 2,894,394 |
| `a` x 1,024 | 1,024 | 182,511 |
| `é` x 1,024 | 2,048 | 2,894,601 |

Deploying is about 13M gas: 51 KB of tables in 3 data contracts (11.2M) and `ENSNormalize` (8 KB, 1.8M). Deploy `ENSNormalizeData0`, `1`, `2`, then `ENSNormalize` with their addresses, each in its own transaction (under the EIP-7825 cap of 16.7M); `ENSNormalizeDataDeployer.deploy()` does this from a forge script.

## How it works

`normalize(label)`:

1. **ASCII Fast Path:** if every byte is valid ascii (`a-z0-9-_$`) or `A-Z`, lowercase it and check the underscore and label extension (`??--`) rules. No table reads.
2. **Decode:** UTF-8 into codepoints.
3. **Tokenize:** at each codepoint, take the longest emoji (FE0F is optional where it appears in the fully-qualified form, and dropped from the output). Otherwise a codepoint is valid, mapped, ignored, or disallowed (revert).
4. **NFC:** each text run. A quick check (NFC_QC and canonical order) skips it for text that's already NFC. Otherwise: decompose, reorder, compose.
5. **Validate:** underscore only at the start; ascii labels can't have `--` at 3-4; a text run can't start with a combining mark; fenced characters can't be leading, trailing, or adjacent; the label's group is the highest priority group that contains every text codepoint; for groups without a CM whitelist, a CM's base must be primary in the group, and the NFD can't have duplicate or more than 4 consecutive non-spacing marks; whole-script confusables.
6. **Encode:** UTF-8.

Groups are bits of a `uint256` (171 groups), so group selection is an AND of each codepoint's mask, and the whole-script confusable check is a few ANDs:
the label is confusable if no codepoint is unique to one group, it has a confused codepoint, and some group is in every confused codepoint's complement (the groups of its whole outside its extent) and contains every other codepoint.

## Data layout

`scripts/make.ts` derives the tables, replays every lookup through the encoded bytes, and writes `src/generated/ENSNormalizeData.sol`: one contract per 24 KB of data (each starts with STOP), the section offsets, and the codehashes.
Every table is random access, since the contract can't decode a compressed stream on every call.

| section | bytes | what |
|---|--:|---|
| INDEX | 2,042 | `cp >> 8` => offset of its bucket in RUNS (codepoints from `LIMIT` = 0x3FD00 up are disallowed, except the ignored E0100-E01EF) |
| RUNS | 15,372 | a bucket: `[n-1][starts: n bytes][values: n x u16]`, identical buckets are shared. A value is a class id, or `0x8000` + an offset in MAP |
| CLASSES | 3,204 | 801 class records (u32): mask id, combining class rank, NFC_QC, CM, NSM, confused, unique, has decomposition, emoji node, valid, ignored, fenced |
| EMOJI | 4,997 | emoji DAWG (227 nodes): `[terminal << 7 \| n][(cp: u24, node: u8) x n]` |
| MAP | 11,040 | mappings: linear (`cp + delta`), or a table of n codepoints of 2 or 3 bytes |
| MASKS | 816 | mask id => (all groups, primary groups) |
| LISTS | 1,730 | a group mask as a list of bit indices |
| CONF | 6,713 | confused codepoints (sorted) => their whole's groups and their extent's groups |
| DECOMP | 1,827 | canonical decompositions reachable from valid codepoints |
| COMP | 3,294 | compositions whose parts can occur |

A lookup reads `INDEX`, finds the run in the bucket (counting 32 run starts per word with SWAR), and reads the class record.
The current bucket, bucket 0 (ascii), class records, and the last group mask are cached in memory for the call.

## Layout

| path | what |
|---|---|
| `src/ENSNormalize.sol` | the contract |
| `src/IENSIP15.sol` | interface, from contracts-v2 |
| `src/generated/ENSNormalizeData.sol` | **generated:** data contracts, layout constants, `ENSNormalizeDataDeployer` |
| `scripts/make.ts` | spec => tables (`scripts/nf.ts`: NFC/NFD) |
| `scripts/download.ts` | fetches the spec and tests |
| `test/ENSNormalize.t.sol` | tests.json, examples |
| `test/Gas.t.sol` | gas report |
| `test/Long.t.sol` | long labels |
