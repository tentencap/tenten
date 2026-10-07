# TenBlocks keeper

An automatic keeper with two jobs, one wallet:

1. **Game keeper** (no privileges: every call is permissionless on chain). It resolves rounds in order (fetching the drand beacon from public relays), closes and converts epochs, feeds the holders queue, releases stuck epochs and carry, sweeps the buyback and operations shares, and skips refundable rounds. It simulates each call first and sends only what would succeed.
2. **Daily HolderPot run** (the pot operator role): at 12:00 UTC it computes the time-weighted TEN v1 balances of the previous 24 hours, shares the pot pro rata (excluding the listed system addresses), applies the $0.25 minimum with carry-over and 90-day expiry, writes the snapshot file with its SHA-256 hash, and pushes the payments through `HolderPot.push` in batches of 250 (the hash is the `ref` of the on-chain event). The rules are in `docs/HOLDER_RULES.md`.

The keeper never writes the private key anywhere. It is read only from `KEEPER_PRIVATE_KEY` in the environment. **Without a key, or with `DRY_RUN=1`, it only reads and logs what it would do.**

## Setup
```bash
cd keeper && npm install
cp ../docs/abi/TenBlocks.json src/abi/TenBlocks.json    # after any contract change
npm test                                           # 17 tests of the pure logic
```
Environment (see `src/config.ts`): `GAME`, `POT` (required); `KEEPER_PRIVATE_KEY` (live mode); `RPC_URL`, `DRAND_RELAYS`, `STATE_DIR` (default `./state`), `MIN_PAYOUT_USD` (0.25), `EXPIRY_DAYS` (90), `PAYOUT_HOUR_UTC` (12), `POLL_MS` (20000), `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` (alerts on errors or a low keeper balance) or `ALERT_WEBHOOK` (a URL that receives `{text}`), `MIN_KEEPER_ETH`.

```bash
npm run bootstrap   # once: builds the TEN v1 balance ledger from the token's first block (about 2 minutes)
npm run dry         # one cycle, nothing sent
npm start           # loop (run it as a service, for example with systemd)
```
State: `state/holders.json` (balance ledger, carried amounts, last paid day), `state/snapshots/YYYY-MM-DD.json` (published for transparency), `state/status.json` (for monitoring).

## Tested
- Unit tests for the time-weighted balance, shares, minimum/carry/expiry, drand parsing and relay fallback.
- End to end on a local anvil fork of the real chain with a test harness contract (random number accepted from the keeper, a fake drand relay in `scripts/mock-drand.mjs`) and the real pools and TEN v1 data: resolve, close epoch, convert through SwapRouter02, release carry, and a daily payment of 357 holders (156 carried) in two batches. The harness (`script/LocalHarness.s.sol`) is for local testing only.
- Not yet tested: a real drand beacon in the loop (the rehearsal on the real chain does this), and a long unattended run.
