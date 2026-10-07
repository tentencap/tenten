# TenBlocks specification (v3: owner-adjustable settings, new split)

Status: matches `src/TenBlocks.sol` and `src/HolderPot.sol` after the owner change. Chain facts were verified with `cast` against the public RPC on 2026-10-05. The code was reviewed internally several times during development and every finding was fixed and tested; it has **not** been audited by a third party.


What changed since v2: the contract is no longer ownerless. An **owner** (a multisig, Safe) can change a defined set of settings, inside hard bounds, with a public delay, and never for a round that already has a deposit. The split is now 90% ETH / 5% wsNET (winners) / 2% ETH Payload / 1% wsNET (TEN holders) / 1% ETH buyback / 1% ETH operations. Conversion is checked every 15 minutes.

---

## 0. Principles

1. **The owner changes settings, never funds.** No function lets the owner (or anyone) take player ETH or wsNET it does not own or pause the game. A round that has started keeps its split, odds, cap and limits; four things are read when they are used and follow the current settings after the 24 h delay: the claim fee (which can only be lowered, never raised above 10%), the swap tolerance (at most 7%), the holders sink, and the buyback and operations wallets.
2. **Hard bounds.** Every adjustable setting has a minimum and maximum in the code; the owner cannot go outside it.
3. **Public delay.** A change is visible on-chain at once and applies after `PARAMS_DELAY` (24 h). Anyone can apply it after the delay.
4. **Rules frozen per round.** A round plays under the settings that were current at its first deposit.
5. **The owner can give up the role for good** (`renounceOwnership`); settings are then frozen.
6. ETH comes in only through `deploy` / `resolveAndDeploy`. ETH goes out only to winners (claims), depositors (refunds), the resolver (tip), the operations and buyback wallets (sweeps) and the swap router (conversion).
7. wsNET comes in only from the conversion swap; it goes out to claimers and to the holders sink.
8. Every outbound leg that can fail (swap, donation, tip) is isolated and never blocks a round.
9. Everything that can get stuck has a permissionless exit that needs no admin (section 11).

---

## 1. Settings

### 1.1 Immutable (constructor `Config`)

| Name | Value | Why |
|---|---|---|
| `WSNET`, `WETH`, `USDG`, `ROUTER` | `0x63C1…86eA`, `0x0bd7…ad73`, `0x5fc5…d168`, SwapRouter02 `0xcaf6…5cb2` | conversion route; a swappable route would let the owner redirect swaps. `router.WETH9()` is checked |
| `POOL_ETH_USDG`, fee | `0x52e6…71Ca`, 100 (0.01%, the deep pool) | fee checked against `pool.fee()` |
| `POOL_USDG_WSNET`, fee | `0x8315…e4DC`, 10000 | the only wsNET/USDG v3 pool; fee checked |
| `GENESIS_TIME` | at least `now + TWAP_SECONDS` | the TWAP window must fill before round 0 |
| Round 90 s / betting 60 s | constants | randomness safety |
| `BEACON_BUFFER` | 12 s | beacon is the first drand round strictly after `bettingEnd + 12 s` |
| `REFUND_TIMEOUT` | 24 h | rounds unresolved this long after the beacon unlock can be refunded |
| `CARRY_TIMEOUT` | 3 days | carry with no winner is released to the rounds that fed it |
| `EPOCH_MAX_ETH` | 0.25 ETH (the unit tests use 0.2) | an epoch closes when it reaches this; a single round can still exceed it (a round's amounts stay together), holders' ETH enters in pieces of at most this size (section 6) |
| `EPOCH_MAX_AGE` | **15 min** | a part-filled epoch closes after this |
| `MIN_EPOCH_ETH` | **0.003 ETH (about $8)** | below this an epoch waits for `CONVERSION_TIMEOUT` before it closes by age (gas would be more than 0.3% of the swap) |
| `TWAP_SECONDS` | 1800 (at most 1 day) | price check window |
| `CONVERSION_TIMEOUT` | 3 days | an unconverted epoch is released: winners are paid in ETH at face value |
| `DORMANCY` | 90 days | with no winning round the Payload joins the holders' bucket |
| `PARAMS_DELAY` | 24 h (1 h to 30 days allowed) | delay between proposing and applying settings |
| `MAX_RECORDS` 25, `MAX_RESOLVE_BATCH` 16, `DUST_FLOOR` 1e9 | constants | |

### 1.2 Adjustable by the owner (`Params`), with hard bounds

| Setting | Initial | Bound |
|---|---|---|
| `winnerCredBps` (wsNET to winners) | 500 (5%) | the five shares below sum to at most 1,500 bps: winners keep at least 85% in ETH |
| `holdersBps` (wsNET to TEN holders) | 100 (1%) | (included in the sum) |
| `payloadBps` (ETH Payload) | 200 (2%) | (included in the sum) |
| `buybackBps` (ETH to the buyback wallet) | 100 (1%) | (included in the sum) |
| `opsBps` (ETH operations, resolver tip first) | 100 (1%) | (included in the sum) |
| `payloadOdds` (1 in N) | 625 | 100 to 2,000, and `payloadCapMult * 10000 <= payloadOdds * (holdersBps + buybackBps + payloadBps)` so a Payload hunter's expectation stays negative (the operations share does not count: a hunter resolving its own tiny round gets it back as the tip). With the defaults the ratio is 4.0% against 4.0% (the maximum the rule allows at odds 1 in 625; the hunter's expectation is about -0.05% before gas and negative after it). Odds 1 in 500 would need a cap of at most 20; raising the cap needs a larger Payload share or lower odds |
| `payloadCapMult` (a hit pays at most N x the round's wager) | 25 | 5 to 100 |
| `claimFeeBps` (fee on unrefined wsNET) | 1,000 (10%) | can be lowered, **never above its initial value** (`CLAIM_FEE_MAX`) |
| `maxDeviationBps` (swap tolerance on top of pool fees) | 300 | 100 to 700 |
| `minPerSquare` | 1e13 wei (0.00001 ETH) | 1e9 to 1e15 |
| `minDeployTotal` | 1e14 wei (0.0001 ETH) | at least `minPerSquare`, at most 0.01 ETH |
| `maxPerPlayerRound` | 2.5 ETH | at least `minDeployTotal`, at most 100 ETH |
| `maxPerRound` | 10 ETH | at least `maxPerPlayerRound`, at most 1,000 ETH |
| `tipCap` (resolver tip) | 0.00003 ETH | at most 0.01 ETH |
| `holdersSink` | HolderPot (v1) or TEN v2 | must be a contract |
| `deploysOpen` | true | false: new rounds take no deposits (resolve, claim, refunds, conversion keep working). Reversible with the same delay. This is how the game is closed |
| `buybackWallet`, `opsWallet` | Safe addresses | non-zero and able to receive ETH (checked at proposal time) |

How a change works: `proposeParams(Params)` (owner only, validated against the bounds, replaces a pending proposal) sets `effectiveAt = now + PARAMS_DELAY`; `cancelParams()` drops it; after `effectiveAt` anyone calls `applyParams()` and a new settings version becomes current. A round stores the version id at its first deposit (`paramsId`); deploy limits, the split, the Payload odds and cap, and the tip cap of that round come from that version. Wallet and sink addresses and the claim fee and swap tolerance are read at the time they are used (sweep, conversion, refine), so they follow the current version after the delay.

Owner: `transferOwnership` + `acceptOwnership` (two steps; accepting cancels any pending proposal of the previous owner), `renounceOwnership` (settings frozen, pending proposal cancelled). The owner address is set in the constructor (`address(0)` is allowed: no owner from day one).

---

## 2. Round timeline

For round `r`: `start = GENESIS + 90 r`, `bettingEnd = start + 60`, `beaconUnlock = bettingEnd + 12`. The deciding drand evmnet round is `T(r) = (beaconUnlock(r) - 1727521075)/3 + 2`, the first one produced strictly after `beaconUnlock`.

`deploy` only for the current round and `now < bettingEnd`. `resolve` only once `now >= beaconUnlock` and before `beaconUnlock + REFUND_TIMEOUT`. A round that has deposits and is unresolved at `beaconUnlock + REFUND_TIMEOUT` is refundable.

Round status: 0 none, 1 has deposits (unresolved), 2 resolved with a winner, 3 resolved with an empty winning square, 4 skipped (refundable).

---

## 3. Functions

### Players
- `deploy(squares, amounts)` payable and `resolveAndDeploy(round, sig, squares, amounts)` payable. Checks (against the round's settings): current round and inside the betting window; `msg.value >= minDeployTotal`; squares non-empty, distinct, below 25; each amount at least `minPerSquare`; `msg.value == sum` exactly; player total at most `maxPerPlayerRound`; round total at most `maxPerRound`; at most 25 records. No ETH is sent during a deploy. If another resolver already resolved the given round, or it is already refundable, `resolveAndDeploy` skips that step and still deploys.
- `claim(rounds, takeWsnet)` / `claimTo(to, rounds, takeWsnet)`: the ETH part (`potEth * stake / winnerTotal`, last claimer gets the exact remainder; includes the Payload when it hit) at once; the wsNET pool part once the round's epoch is converted (or in ETH at face value if released). With `takeWsnet` the whole mined balance is refined.
- `withdraw()` / `withdrawTo(to)`, `checkpoint(account)`.
- `refund(r)` / `refundTo(to, r)`, `refundEmpty(r)` / `refundEmptyTo(to, r)`.

### Permissionless housekeeping
`resolve(r, sig)`, `resolveMany(rs, sigs)` (at most 16; resolved rounds skipped), `skipRefundable(r)`, `releaseCarry()`, `convert()`, `convertEpoch(i)`, `closeEpoch()`, `releaseEpoch(i)`, `flushHolders()`, `sweepPayload()`, `feedHolders()`, `sweepOps()`, `sweepBuyback()`, `applyParams()`.

### Owner
`proposeParams`, `cancelParams`, `transferOwnership`, `acceptOwnership`, `renounceOwnership`.

Resolve preconditions: status 1, beacon unlocked, not refundable, previous deposited round resolved or skipped (**strict order**). The drand BLS signature for `T(r)` is verified in the contract (library vendored from `kevincharm/bls-bn254` through SLVR, hardcoded evmnet key). Measured with real beacons: 325k to 355k gas. `rv = sha256(sig)`; `square = keccak256(rv, r, "sq") % 25`; hit roll `keccak256(rv, r, "pl") % payloadOdds == 0`. The caller receives the resolver tip after all state changes; a caller that cannot receive ETH forfeits it to operations.

---

## 4. Split and formulas

For a round with wager `W` under settings `P` (all floors; the rounding remainder goes to the winners' ETH pot):

- `winnerCredit = W * winnerCredBps / 10000` (wsNET value, in ETH until conversion)
- `holders = W * holdersBps / 10000` (wsNET value, to the holders sink)
- `payload = W * payloadBps / 10000` (ETH, joins `payloadEth`)
- `buyback = W * buybackBps / 10000` (ETH, accrues to `buybackAccrued`)
- `ops = W * opsBps / 10000` (ETH): tip `= min(ops, tipCap)` to the resolver, `ops - tip` to `opsAccrued`
- `ethPot = W - winnerCredit - holders - payload - buyback - ops`

Default: 90% / 5% / 1% / 2% / 1% / 1%. A full-grid player against even coverage gets about 90% ETH + 5% wsNET + about 2% Payload, about 97% gross (about -3%).

**Payload.** `payloadEth` grows by each round's share (also empty rounds). In a round with a winner the hit roll succeeds with probability 1 in `payloadOdds`; the winners' pot then gets `min(payloadEth, payloadCapMult * W)`; the rest stays. Paid through the normal ETH claim.

---

## 5. Ordering, carry and carry release

Rounds with deposits resolve strictly in order, so a resolver cannot pick which round receives the carry or the Payload. If the winning square is empty, `carryEth += ethPot` and `carryCredit += winnerCredit`; the holders, Payload, buyback and operations shares go through normally. At the next round with a winner, `potEth = ethPot + carryEth`, `credEth = winnerCredit + carryCredit`. `releaseCarry()` (after `CARRY_TIMEOUT` counted from the latest empty round, with no winner since and no unresolved deposited round) marks the chain released; each empty round in it then refunds `(potEth + credEth) * theirStake / totalWager` through `refundEmpty`.

---

## 6. Conversion (as built)

The wsNET shares (`winnerCredit` and `holders`) sit in ETH in an **epoch** and are converted in batches by anyone, about every 15 minutes when there is enough to be worth the gas.

- An epoch closes when its total reaches `EPOCH_MAX_ETH`, or by age (`closeEpoch()` or inside `convert()`): after `EPOCH_MAX_AGE` if it holds at least `MIN_EPOCH_ETH`, after `CONVERSION_TIMEOUT` otherwise. `closeEpoch()` is its own transaction, so a failing swap cannot undo it.
- Gas is about $0.025 per conversion: swapping less than about $8 costs more than 0.3% in gas, which is why a small pot waits.
- Route: `ETH -> WETH -> USDG` (v3 0.01%) then `USDG -> wsNET` (v3 1%), one `exactInput` on SwapRouter02. `minOut = TWAP quote of both pools, net of pool fees, times (1 - maxDeviationBps)`. A revert keeps the epoch closed and waiting; the output is measured as a balance delta.
- On success `rate = out * 1e18 / ethIn`; the winners' pool is `ethCred * rate / 1e18` (reserved and stamped with `minerIndex`), the holders get the rest, sent to `holdersSink.donateReward(wsNET, amount)` with a raw call (no return data copied) capped at 800k gas, and the caller must supply enough gas (about 1.1M) for the call and the code after it; whatever it does not pull is parked in `holdersOwed` (`flushHolders()` retries).
- Epochs are independent: `convertEpoch(i)` converts any closed epoch; a stuck one does not block the others. An epoch can exceed `EPOCH_MAX_ETH` when a round consumes a long carry chain.
- `releaseEpoch(i)`: a **closed** epoch unconverted for `CONVERSION_TIMEOUT` is released (an open epoch must first be closed with `closeEpoch()`, which persists): winners are paid their credit in ETH at face value, the holders' ETH goes to `holdersEthPending`. The same pending bucket receives the Payload ETH after `sweepPayload`. `feedHolders()` (also run at the start of `convert()` and `closeEpoch()`) moves it into the open epoch **at most `EPOCH_MAX_ETH` at a time**, so a large amount cannot form one epoch the pool cannot absorb. A round's own amounts stay together in one epoch; the current epoch is closed before a round that would push it over the cap.

---

## 7. Claim fee and dividend index (adapted from `SlvrMinerVault`)

Terms: mined wsNET is **unrefined** (`bal`): refining it costs `claimFeeBps` (10%). wsNET earned from other players' fees is **refined** (`accrued`): never taxed. Example: 5 unrefined + 5 refined, fee 0.5, you receive 9.5.

- Credit a pool reward `R`: checkpoint, `bal += R`, `reservedWs -= R`, backdate `accrued += R * (minerIndex - epoch.index) / WAD`.
- Checkpoint: `accrued += bal * (minerIndex - snap) / WAD`, clamped by `totalAttributed <= totalRefined`.
- Refine: `remaining = totalUnclaimed - bal`; if `remaining >= DUST_FLOOR`: `fee = bal * claimFeeBps / 10000`, `inc = fee * WAD / remaining` (no fee if `inc == 0`); `payout = bal + accrued - fee`; `minerIndex += inc`.
- The fee is not burned: it is shared by everyone who has not refined. A lone last holder pays no fee. Unclaimed wsNET never expires.
- Known limits inherited from SLVR (documented, not fixed): a tiny holder that never refines collects fees in proportion to its weight and, when it is nearly alone, a last refiner's whole fee; splitting funds over many addresses lowers the fee a large holder pays; abandoned balances keep a share and their dividends stay unattributed.

---

## 8. Holders sink and TEN v1

The holders' share goes to `holdersSink.donateReward(wsNET, amount)`.

- **TEN v2:** the token's own reward engine (not live; check the real contract before use: gas under 800k, behaviour with zero reward base).
- **TEN v1:** `HolderPot` (`src/HolderPot.sol`). TEN v1 has no reward engine, so the pot receives the wsNET and an operator (an automatic keeper) pushes it to v1 holders once a day at 12:00 UTC, pro rata to the time-weighted balance, off-chain computed (rules in `docs/HOLDER_RULES.md`; system wallets excluded, minimum $0.25 per holder, smaller amounts carried to the next round, carried amounts expire after 90 days). The pot has an **owner** (the Safe) that can replace the operator at once with `setOperator` (the operator cannot replace itself). The pot is **not trustless**: the operator chooses recipients and amounts; every push carries a reference to the published snapshot so it can be audited. Only wsNET can leave, a failing recipient is skipped and its amount stays in the pot, the owner (Safe) can replace the operator at once.
- Moving from v1 to v2 is a settings change of `holdersSink` (with the 24 h delay). To close the game first, set `deploysOpen = false` (new rounds take no deposits; everything already played still resolves, pays and refunds; nothing expires), then relaunch a new game if wanted.

---

## 9. Buyback and operations wallets

`sweepBuyback()` and `sweepOps()` send the accrued ETH to the current wallet, permissionless. The buyback wallet is a normal wallet (the plan: a Safe) that buys TEN and donates it to the TEN Permanent Reserve (`0x4fC94FD0…`, TEN only); it is a trust point and must be disclosed. A buyback inside the contract was rejected (thin TEN pool, no TWAP, NET tax).

---

## 10. Escape paths (no admin)

| Situation | Exit |
|---|---|
| Round unresolved 24 h after beacon unlock | `refund` / `refundTo`, `skipRefundable` |
| Carry with no winner for 3 days | `releaseCarry`, `refundEmpty` / `refundEmptyTo` |
| Epoch not converted for 3 days | `releaseEpoch` (winners in ETH at face value) |
| Sink rejects or under-pulls the donation | parked in `holdersOwed`, `flushHolders` |
| No winning round for 90 days | `sweepPayload` (Payload ETH joins the holders' bucket) |
| A winner cannot receive ETH | `claimTo` |
| A resolver cannot receive ETH | tip forfeited to operations |

The owner can change the price tolerance but not these timeouts.

---

## 11. Events

`Deployed`, `Resolved(round, square, winnerTotal, potEth, credEth, payloadPaid, epoch, carried)`, `Claimed`, `Withdrawn`, `EpochClosed`, `Converted(epoch, ethIn, wsOut, wsHolders)`, `EpochReleased`, `HoldersDonated`, `Refunded`, `RoundSkipped`, `CarryReleased`, `PayloadSwept`, `OpsSwept`, `BuybackSwept`, `TipPaid`, `ParamsProposed(effectiveAt, params)`, `ParamsApplied(id, params)`, `ParamsCancelled`, `OwnershipTransferStarted`, `OwnershipTransferred`.

---

## 12. Invariants (tests)

1. **ETH:** `balance == unresolved stakes + carryEth + carryCredit + payloadEth + opsAccrued + buybackAccrued + unpaid pots + epoch ETH (open/closed) + released-epoch credit unpaid + released empty-round refunds unpaid + skipped-round stakes unrefunded`, exactly, in every state.
2. **wsNET:** `balance >= totalUnclaimed + totalRefined + holdersOwed`, surplus only rounding dust.
3. **Index:** `totalAttributed <= totalRefined`; `totalUnclaimed == reservedWs + sum of balances`.
4. **Rounds:** `paidEth <= potEth`; claimed stake never exceeds the winning total.
5. **Order:** a round resolves only after its predecessor is resolved or skipped.
6. **Owner:** no function reaches player funds; settings always inside bounds; a round never changes settings after its first deposit.

---

## 13. Tests and tools

Unit, fuzz and handler-based invariant tests; real drand beacons through the real BLS code; fork tests on the latest block of the real chain; settings tests (bounds, delay, per-round freezing, sink and wallet changes, two-step ownership, renounce); HolderPot tests including the game-to-pot flow; `slither`. Not done: a third-party audit.

---
