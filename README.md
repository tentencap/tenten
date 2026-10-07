# TenTen: TenBlocks

Smart contracts and keeper software for TenBlocks, a 5x5 ETH grid on Robinhood Chain (chain id 4663). Part of the revenue is paid in wsNET to TEN v1 holders.

This is experimental software that handles real money. It has not been audited by a third party. Read `docs/SPEC.md` before using it.

## Layout

| Path | What it is |
|---|---|
| `src/TenBlocks.sol` | The game: rounds, deploys, resolution with drand randomness, claims, settings with a public delay |
| `src/HolderPot.sol` | The rewards pool that pays TEN v1 holders (operator pushes the daily payments) |
| `src/lib/` | BLS signature verification used for the drand beacon (third-party code, see `LICENSE-THIRD-PARTY.md`) |
| `script/` | `Deploy.s.sol`, `Verify.s.sol` (post-deployment checks), `LocalHarness.s.sol` (local testing only) |
| `test/` | Unit, fuzz, invariant, BLS and fork tests |
| `keeper/` | TypeScript keeper: resolves rounds, converts epochs, runs the daily holder payment. See `keeper/README.md` |
| `docs/SPEC.md` | Specification |
| `docs/HOLDER_RULES.md` | Rules of the daily holder payment |
| `docs/abi/` | Contract ABI |

## Build and test

Dependencies are pinned in `foundry.lock` and are not committed:

```bash
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0 Uniswap/v4-core@v4.0.0 --no-git
forge build
forge test --no-match-contract Fork          # unit, fuzz, invariant, real-BLS tests
forge test --match-contract ForkTest -vv     # fork tests against the latest block of the real chain
```

Fork tests use the public RPC alias `robinhood` from `foundry.toml`. The RPC has no historical state, so they fork the latest block.

The contract is larger than the Ethereum 24 KB limit and relies on the 96 KB limit of Robinhood Chain, so deployment scripts need `--code-size-limit 98304`.

## Deploying

`script/Deploy.s.sol` runs as a dry run unless `--broadcast` is passed, and never reads a private key itself: sign with a hardware wallet or an encrypted keystore (`--ledger`, `--trezor`, `--account`). Environment variables: `PROFILE` (`rehearsal` or `production`), `OWNER`, `KEEPER`, `BUYBACK_WALLET`, `OPS_WALLET`, `GENESIS_DELAY`. A dry run does not predict contract addresses reliably; use the addresses printed by the real broadcast, then run `script/Verify.s.sol` with `GAME` and `POT` set.

## License

Original code: see the SPDX headers of each file. Third-party notices: `LICENSE-THIRD-PARTY.md`.
