# Daily rewards for TEN v1 holders (rules, v1 of the rules)

Status: decided by the TenTen team on 2026-10-05; to be published on the site before launch. TEN v1 has no on-chain reward engine, so these rules are executed off-chain by an automatic keeper and paid through `HolderPot`. The rewards pool is the one part of the v1 setup that is **not trustless**: the keeper chooses the recipients and the amounts, so the rule below is published and every payment can be recomputed by anyone.

## What is paid

The wsNET that TenBlocks sends to the holders sink (1% of the deploys, converted from ETH). It arrives in `HolderPot` through `donateReward`. Nothing else is paid from the rewards pool.

## When

- Period: 12:00 UTC to 12:00 UTC (24 hours).
- The payment run starts at 12:00 UTC right after the period closes and should finish within an hour.

## Who and how much

1. **Basis.** The *time-weighted average balance* of TEN v1 over the period, from the token's `Transfer` events (not a single-block snapshot, so buying just before and selling just after earns almost nothing). If this turns out hard to compute reliably, the fallback is a snapshot at 00:00 UTC of the day.
2. **Eligible.** Every address that held TEN v1 during the period, except the exclusions below. Team wallets are included. Contracts not on the exclusion list are included (wallets with EIP-7702 delegation count as users); a transfer to a contract that cannot use wsNET is the holder's responsibility.
3. **Share.** `share_i = TWAB_i / sum of TWAB of eligible holders`. `amount_i = floor(share_i * pot)`, where `pot` is the wsNET balance of the rewards pool at 12:00 UTC (rounding remainders stay in the rewards pool).
4. **Minimum distribution.** $0.25 per holder, valued at the wsNET price at distribution time (30-minute TWAP of the wsNET/USDG pool). A holder whose accumulated amount is below the minimum is not paid that day: the amount is carried to the next period and added to what the holder earns then. At the planned volume this is a gas efficiency rule, not a restriction: a transfer costs about $0.004 of gas, so $0.25 means gas stays around 1.6% of a payout. It can be lowered later without touching any contract.
5. **Expiry of carried amounts.** A carried amount that has not reached the minimum after 90 days returns to the rewards pool and is shared again in the next period.

## Exclusions (never paid)

The list lives in `keeper/src/exclusions.ts` (the first part is the verified list of `tenten-reward-indexer-v2`). The team's rule: everyone else is included, team wallets too.

- Uniswap v4 PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` (it holds the TEN/NET pool's tokens) and the TEN/wsNET Uniswap v2 pair `0x9D464361766aF710a497f8CFf91c87b56bD17f20`.
- PAR contracts and relays: factory `0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F`, router `0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120`, locker `0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231`, FeeEscrow `0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386`, vault `0x4B79B8298cd890A82dC9De1dE5dBb745Cf04353C`, disperse `0x28a5f3F898E99753E322fdce6EFa8b294C215B9b`, and the PAR reward distributor `0xB1a7a3A37F41e4dC9507F9B0F946B7F786c4AFb4` (an externally owned account that pays PAR rewards).
- The TEN Permanent Reserve `0x4fC94FD08Ff44abde7452BB109f1C5ab937ED4e3` (it only accepts TEN: wsNET sent there would be stuck forever).
- The reward reserves `0xC05ddFbd4f9a46ae297b286D4D6998a0c0Ea27FE` (V2) and `0x313dfCB9E091D33482e75EEFa00E0156b42119b5` (V1, abandoned).
- The TEN token contract itself, the dead address (`0x000...dEaD`), the zero address, `HolderPot` and the TenBlocks contract.

PAR's admin, keeper and protocol-fee wallets are ordinary wallets and are **not** excluded unless the team decides otherwise.

## Start and end

- Starts with the test deployment (the rehearsal), with the same rules.
- Ends when new deploys are blocked (`deploysOpen = false`, section "Closing TenBlocks" below): after the last rounds are resolved and the last epochs are converted or released (up to about 3 days), a final payment empties the rewards pool (carried amounts below the minimum are paid in the final run).

## Operator

An automatic keeper (a dedicated wallet that holds only ETH for gas) pushes the payments (`HolderPot.push`, at most 250 recipients per call; several calls per run). The rewards pool's owner (the Safe) can replace the operator at once with `setOperator` if the keeper is compromised. The rewards pool is emptied every day, so a compromised keeper can move at most one day's rewards. Every payment carries a reference (the SHA-256 of the published snapshot) in its `Pushed` event.

## Transparency (on the site)

For each period: the snapshot file (eligible addresses, TWAB, amounts, carried ledger), its hash, the transaction hashes of the pushes, today's rewards pool, and a read-only lookup by address (no wallet connection). The script that computes the snapshot is open source so anyone can recompute it.

## Planned size

Target volume $30,000 to $40,000 a day: the rewards pool receives about $300 to $400 a day (1%). With about 500 eligible holders the gas of a daily run is about $2 (0.6%). A holder reaches $0.25 in one day if they own more than about 0.07% of the eligible time-weighted balance.

## Closing TenBlocks and moving to TEN v2

If PAR stops paying and TEN v2 must be launched: (1) the owner proposes `deploysOpen = false` (public 24 hours before it applies); new rounds then take no deposits while resolution, claims, refunds and conversion keep working; (2) wait for the last rounds to be resolved and claimed, and for the last epochs to convert or release; final rewards pool payment; (3) launch TEN v2; (4) start a new TenBlocks (or, if the settings allow, reopen this one) whose holders sink is TEN v2. Participants in the old TenBlocks can claim for as long as they want: nothing expires.
