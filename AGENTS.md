# AGENTS.md

Guidance for AI coding agents working in this repo. See README.md for the design and data layout.

## What this is

ENSIP-15 label normalization in Solidity: `ENSNormalize` implements `IENSIP15` (`normalize(label)` returns the normalized label or reverts `CannotNormalize`). The algorithm follows the reference implementation in [ens-normalize-derive](https://github.com/adraffy/ens-normalize-derive) (`src/ensip15.ts`), and the tables are derived from its spec files (`spec.json`, `nf.json`). The priorities are:

1. **Correctness:** every entry of ens-normalize-derive's `tests.json` must pass (output, or revert when `error` is set).
2. **Gas:** `normalize()` should stay cheap, and ASCII comes first: most labels are `a-z0-9-`. Check the gas report for every change to the contract.
3. **Deploy size:** the tables are deployed as code (about 51 KB: 17 KB in `ENSNormalize`, the rest in 2 data contracts; about 12M gas). Check the sizes printed by `bun run make` for every change to the encoding.

The deployment is immutable and ownerless: no admin, no upgrades. A new spec is a new deployment.

## Commands

Requires [Foundry](https://getfoundry.sh) and [Bun](https://bun.sh).

```sh
bun install
bun run download          # data/{spec,nf,tests}.json from ens-normalize-derive (main); --force to refetch
bun run make              # data/*.json => src/generated/ENSNormalizeData.sol, prints section sizes
forge test                # everything, incl. tests.json (about 45s, 8 parallel shards)
forge test --nmt test_tests          # quick: skip tests.json
forge test --mc GasTest -vv          # gas report (normalize + deploy), writes snapshots/
forge test --mc ProbeTest --flamegraph   # where the gas goes, per internal function (write a throwaway test)
forge build --sizes       # ENSNormalize must stay under 24,576 bytes
forge fmt
```

Run `bun run make`, `forge fmt --check`, and `forge test` before considering a change done. Commit `snapshots/` and report the gas change (`git diff snapshots/`) and, for encoding changes, the size change.

GasTest measures the call itself (not the test's overhead), and forge treats every account as cold on each call: the numbers include 2600 for each data contract a label reads.

## Layout

| path | what |
|---|---|
| `src/ENSNormalize.sol` | the contract: ascii fast path, UTF-8, tokenize (emoji DAWG, mapped/ignored), NFC, validation |
| `src/IENSIP15.sol` | interface, copied from ensdomains/contracts-v2 |
| `src/generated/ENSNormalizeData.sol` | **generated, do not edit:** file-level constants (section offsets, counts, hashes), `TABLES`, data contracts, `ENSNormalizeDataDeployer` |
| `scripts/make.ts` | spec => tables; replays every lookup through the encoded bytes and throws on a mismatch |
| `scripts/nf.ts` | NFD/NFC from `nf.json` (used by make.ts) |
| `scripts/utils.ts` | byte writer, keccak (`@adraffy/keccak`) |
| `scripts/download.ts` | fetches the spec and tests |
| `test/ENSNormalize.t.sol` | tests.json (sharded), examples, invalid UTF-8, constructor checks, `test_tables` |
| `test/Lookup.t.sol` | the contract's `_lookup()` of every codepoint vs `LOOKUP_HASH` from make.ts |
| `test/TestsJSON.sol` | minimal JSON parser for tests.json (forge's cheatcodes coerce strings and reject lone surrogates) |
| `test/Gas.t.sol` | gas report |
| `snapshots/` | the gas report's output: `normalize.json`, `deploy.json` |

`data/` is downloaded and gitignored. `src/generated/` and `snapshots/` are committed; CI regenerates the data and fails if it changes.

## Rules

- **Encoder and reader change together.** The class record bits (`C_*`), `RUN_MAPPED`, the bucket size, and every section format are literals in both `scripts/make.ts` and `src/ENSNormalize.sol`. make.ts's self-check mirrors the contract's readers; keep it in sync so a mismatch fails at generation time, not in forge.
- **Regenerate after encoding or spec changes:** run `bun run make` and commit `src/generated/`. Its output must be stable under `forge fmt`.
- **Don't edit `src/generated/`** by hand.
- **Keep parity.** A tests.json failure is a bug. Don't skip or special-case tests; the only conversions are the ones in `test/ENSNormalize.t.sol` (names are split on `.`, `""` is `""`, lone surrogates are U+FFFD).
- **Assumptions are asserted in make.ts** (eg. no mapped emoji start, decomposable cps aren't mapped, one ignored range above `LIMIT`, groups fit in a `uint256`). If a new spec breaks one, change the encoding and the contract, don't drop the assert.
- **Tables in the contract's code.** `TABLES` is a literal that `tables()` returns, and the contract reads it with `CODECOPY` at `codesize() - metadata - TABLES_SIZE` (`_context()`). That works because it's the only data in the runtime code, so solc (legacy codegen) puts it right before the metadata. So:
  - don't add another literal over 32 bytes to `ENSNormalize` (a revert string, a `bytes`/`string` constant): solc orders data by hash and the tables could move.
  - don't enable `via_ir`: it lays out data differently (and the code gets bigger).
  - `test_tables` checks the placement; if it fails, nothing else is trustworthy.
- **Sizes.** `ENSNormalize` must stay under 24,576 bytes (EIP-170): `TABLES_BUDGET` in make.ts is what's left for the tables after the logic (about 7.3 KB) and the metadata. Keep a couple hundred bytes of margin, and check the `hot buckets:` line that make.ts prints: a `!` is a bucket that didn't fit. The hot buckets fill whatever the other tables leave of it, so lower it if the logic grows. Each data section must fit in one contract (24,575 bytes after the leading STOP), and a deploy transaction must stay under the EIP-7825 cap (16,777,216 gas).
- **Generated constants are file-level** (not in a library), because inline assembly can only use direct number constants. A contract constant that's used in assembly must be a literal expression too (not `X = OTHER_CONSTANT`-style member access).
- **A constant that's an expression of other constants isn't folded.** `CTX_SIZE = CTX_SCRATCH + ...` is evaluated wherever it's used, with an overflow check per `+` (about 70 gas each: `ctx + CTX_SIZE` was 350). Use those constants inside `unchecked`, where the optimizer folds them. In general, keep Solidity arithmetic on the hot paths in `unchecked` blocks.
- **Nested `switch` is expensive in assembly:** each level costs a compare to enter and a pop to leave. The hot paths use one level of `for {} 1 {} { if ... { ... break } ... break }`.
- **Gas:** the general path doesn't allocate: `[context][cps][entries][scratch]` are laid out from the free memory pointer, which never moves, and `normalize()` returns from assembly. Don't call anything that allocates there (only the final `revert CannotNormalize(label)` does). `_lookup()` caches the last bucket and `_maskAll()` 4 masks in the context. EVM loops cost about 3 gas per opcode and the legacy optimizer doesn't help assembly much, so count operations: an idea is worth it if it removes operations from the per-codepoint paths (`_classify`, `_lookup`, the `_tokenize` and `_isValid` loops) or avoids a data contract. Measure with GasTest and the flamegraph before keeping it. To see exactly what runs, record the opcodes of a call with `vm.startDebugTraceRecording()` (needs `-vvv`) and look for repeated patterns.
- **EVM version:** `cancun` (no osaka opcodes), so it deploys on chains that haven't adopted osaka.

## Working with the maintainer

- Commit as you go, but don't push unless asked.
- Don't deploy unless asked.
