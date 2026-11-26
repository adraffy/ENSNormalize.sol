# AGENTS.md

Guidance for AI coding agents working in this repo. See README.md for the design and data layout.

## What this is

ENSIP-15 label normalization in Solidity: `ENSNormalize` implements `IENSIP15` (`normalize(label)` returns the normalized label or reverts `CannotNormalize`). It ports the label validation of [ens-normalize.ts](https://github.com/adraffy/ens-normalize.ts), with tables derived from [ens-normalize-derive](https://github.com/adraffy/ens-normalize-derive) (`spec.json`, `nf.json`). The priorities are:

1. **Correctness:** every entry of ens-normalize-derive's `tests.json` must pass (output, or revert when `error` is set).
2. **Gas:** `normalize()` should stay cheap. Check the gas report for every change to the contract.
3. **Deploy size:** the tables are deployed as code (about 51 KB in 3 data contracts, about 13M gas). Check the sizes printed by `bun run make` for every change to the encoding.

The deployment is immutable and ownerless: no admin, no upgrades. A new spec is a new deployment.

## Commands

Requires [Foundry](https://getfoundry.sh) and [Bun](https://bun.sh).

```sh
bun install
bun run download          # data/{spec,nf,tests}.json from ens-normalize-derive (main); --force to refetch
bun run make              # data/*.json => src/generated/ENSNormalizeData.sol, prints section sizes
forge test                # everything, incl. tests.json (about 40s, 8 parallel shards)
forge test --nmt test_tests          # quick: skip tests.json
forge test --mc GasTest -vv          # gas report (normalize + deploy)
forge test --mc LongTest -vv         # long labels
forge fmt
```

Run `bun run make`, `forge fmt --check`, and `forge test` before considering a change done. Report the gas change (GasTest) and, for encoding changes, the size change.

## Layout

| path | what |
|---|---|
| `src/ENSNormalize.sol` | the contract: ascii fast path, UTF-8, tokenize (emoji DAWG, mapped/ignored), NFC, validation |
| `src/IENSIP15.sol` | interface, copied from ensdomains/contracts-v2 |
| `src/generated/ENSNormalizeData.sol` | **generated, do not edit:** data contracts, section offsets/counts, codehashes, `ENSNormalizeDataDeployer` |
| `scripts/make.ts` | spec => tables; replays every lookup through the encoded bytes and throws on a mismatch |
| `scripts/nf.ts` | NFD/NFC from `nf.json` (used by make.ts) |
| `scripts/utils.ts` | byte writer, keccak (`@adraffy/keccak`) |
| `scripts/download.ts` | fetches the spec and tests |
| `test/ENSNormalize.t.sol` | tests.json (sharded), examples, invalid UTF-8, constructor checks |
| `test/TestsJSON.sol` | minimal JSON parser for tests.json (forge's cheatcodes coerce strings and reject lone surrogates) |
| `test/Gas.t.sol`, `test/Long.t.sol` | gas reports |
| `script/Deploy.s.sol` | deploys the data contracts, then ENSNormalize |

`data/` is downloaded and gitignored. `src/generated/` is committed; CI regenerates it and fails if it changes.

## Rules

- **Encoder and reader change together.** The class record bits (`C_*`), `RUN_MAPPED`, the bucket size, and every section format are literals in both `scripts/make.ts` and `src/ENSNormalize.sol`. make.ts's self-check mirrors the contract's readers; keep it in sync so a mismatch fails at generation time, not in forge.
- **Regenerate after encoding or spec changes:** run `bun run make` and commit `src/generated/`. Its output must be stable under `forge fmt`.
- **Don't edit `src/generated/`** by hand.
- **Keep parity.** A tests.json failure is a bug. Don't skip or special-case tests; the only conversions are the ones in `test/ENSNormalize.t.sol` (names are split on `.`, `""` is `""`, lone surrogates are U+FFFD).
- **Assumptions are asserted in make.ts** (eg. no mapped emoji start, decomposable cps aren't mapped, one ignored range above `LIMIT`, groups fit in a `uint256`). If a new spec breaks one, change the encoding and the contract, don't drop the assert.
- **Data contracts:** each section must fit in one contract (24,575 bytes after the leading STOP), and a deploy transaction must stay under the EIP-7825 cap (16,777,216 gas).
- **Gas:** hot loops are inline assembly; `_lookup()` caches buckets, class records, and the last mask in a per-call `ctx`. Memory past the free pointer is used as scratch, so don't allocate between filling scratch and reading it. Measure ideas with GasTest before keeping them; `via_ir` was tried and didn't pay for its build time.
- **EVM version:** `cancun` (no osaka opcodes), so it deploys on chains that haven't adopted osaka.

## Working with the maintainer

- Commit as you go, but don't push unless asked.
- Don't deploy unless asked.
