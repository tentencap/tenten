// The daily HolderPot run: snapshot of TEN v1 time-weighted balances, pro rata shares, minimum payout, push.
import { Contract, JsonRpcProvider, id as keccakId, zeroPadValue } from "ethers";
import type { Config } from "./config.js";
import { exclusionSet } from "./exclusions.js";
import {
  allocate, applyTransfers, computeTwab, minPayoutWei, period, settle, snapshotHash, sortTransfers,
  type Transfer,
} from "./holders.js";
import { loadState, saveState, writeJson, type HolderState } from "./state.js";

const TRANSFER_TOPIC = keccakId("Transfer(address,address,uint256)");
const addrOf = (topic: string) => "0x" + topic.slice(26).toLowerCase();

export async function scanTransfers(p: JsonRpcProvider, token: string, from: number, to: number, range: number): Promise<Transfer[]> {
  const out: Transfer[] = [];
  for (let a = from; a <= to; a += range) {
    const b = Math.min(a + range - 1, to);
    const logs = await p.getLogs({ address: token, topics: [TRANSFER_TOPIC], fromBlock: a, toBlock: b });
    for (const l of logs) {
      if (l.topics.length !== 3) continue;
      out.push({ block: l.blockNumber, logIndex: l.index, from: addrOf(l.topics[1]), to: addrOf(l.topics[2]), value: BigInt(l.data) });
    }
  }
  return sortTransfers(out);
}

/** Last block whose timestamp is at or before `ts` (binary search; the RPC keeps no old state but block headers are available). */
export async function blockAtOrBefore(p: JsonRpcProvider, ts: number): Promise<number> {
  let lo = 0;
  let hi = await p.getBlockNumber();
  const tsOf = async (n: number) => (await p.getBlock(n))!.timestamp;
  if ((await tsOf(hi)) <= ts) return hi;
  while (lo < hi) {
    const mid = Math.ceil((lo + hi) / 2);
    if ((await tsOf(mid)) <= ts) lo = mid;
    else hi = mid - 1;
  }
  return lo;
}

/** Bring the balance ledger up to `block`, saving progress as it goes. */
export async function advanceLedger(p: JsonRpcProvider, cfg: Config, st: HolderState, block: number, save = true): Promise<HolderState> {
  let from = Math.max(st.ledgerBlock + 1, cfg.tenV1GenesisBlock);
  while (from <= block) {
    const to = Math.min(from + cfg.logRange * 5 - 1, block);
    const ts = await scanTransfers(p, cfg.tenV1, from, to, cfg.logRange);
    st = { ...st, balances: applyTransfers(st.balances, ts), ledgerBlock: to };
    if (save) saveState(cfg.stateDir, st);
    from = to + 1;
  }
  return st;
}

async function ethUsd(p: JsonRpcProvider, pool: string): Promise<number> {
  const c = new Contract(pool, ["function slot0() view returns (uint160 sqrtPriceX96,int24,uint16,uint16,uint16,uint8,bool)"], p);
  const s = await c.slot0();
  const sqrt = Number(s.sqrtPriceX96) / 2 ** 96;
  return sqrt * sqrt * 1e12; // WETH (18) is token0, USDG (6) token1
}

export interface RunOptions { final?: boolean; now?: number }

export async function holdersRun(
  cfg: Config, p: JsonRpcProvider, game: Contract, pot: Contract, log: (m: string) => void, opts: RunOptions = {},
): Promise<string> {
  const now = opts.now ?? Math.floor(Date.now() / 1000);
  const { t0, t1, day } = period(now, cfg.payoutHourUtc);
  let st = loadState(cfg.stateDir);
  if (st.lastDay === day && !opts.final) return `period ${day} already paid`;
  if (now < t1 + 60) return "period not closed yet";

  const b0 = await blockAtOrBefore(p, t0);
  const b1 = await blockAtOrBefore(p, t1);
  st = await advanceLedger(p, cfg, st, b0, !cfg.dryRun);
  const transfers = await scanTransfers(p, cfg.tenV1, b0 + 1, b1, cfg.logRange);
  const times = new Map<number, number>();
  for (const b of new Set(transfers.map((t) => t.block))) times.set(b, (await p.getBlock(b))!.timestamp);
  const twab = computeTwab(st.balances, transfers, (b) => times.get(b)!, t0, t1);

  // money: what the pot holds beyond the amounts already owed to carried holders
  const balance = BigInt(await pot.balance());
  const expirySec = cfg.expiryDays * 86400;
  const afterExpiry = settle(st.pending, {}, 0n, now, expirySec, false).pending; // drops expired, pays nothing here
  const owed = Object.values(afterExpiry).reduce((s, x) => s + x.amount, 0n);
  const money = balance > owed ? balance - owed : 0n;

  const wsPerEth = BigInt(await game.twapExpectedOut(10n ** 18n));
  const minWei = minPayoutWei(cfg.minPayoutUsd, await ethUsd(p, cfg.poolEthUsdg), wsPerEth);
  const excluded = exclusionSet([cfg.pot, cfg.game]);
  const shares = allocate(twab, excluded, money);
  const res = settle(st.pending, shares, minWei, now, expirySec, !!opts.final);

  const entries = Object.entries(res.payments).sort(([a], [b]) => (a < b ? -1 : 1));
  const snapshot = {
    day, t0, t1, b0, b1, pot: String(balance), money: String(money), minPayoutWei: String(minWei),
    payments: entries.map(([a, v]) => [a, v.toString()]),
    carried: Object.entries(res.pending).map(([a, v]) => [a, v.amount.toString(), v.since]),
    expiredBackToPot: String(res.expiredTotal),
    holdersCounted: Object.keys(shares).length,
  };
  const ref = snapshotHash(snapshot);
  const dir = cfg.dryRun ? `${cfg.stateDir}/dry` : `${cfg.stateDir}/snapshots`;
  writeJson(dir, `${day}.json`, { ...snapshot, ref });
  log(`period ${day}: pot ${balance}, new money ${money}, ${entries.length} payments, ${Object.keys(res.pending).length} carried, ref ${ref}`);
  if (cfg.dryRun) return `dry run: ${entries.length} payments, snapshot ${dir}/${day}.json`;

  // push in batches of 250; progress is saved so a restart does not pay twice
  const batches: [string[], bigint[]][] = [];
  for (let i = 0; i < entries.length; i += 250) {
    const part = entries.slice(i, i + 250);
    batches.push([part.map(([a]) => a), part.map(([, v]) => v)]);
  }
  const done = st.inflight && st.inflight.day === day ? st.inflight.done : 0;
  if (!st.inflight || st.inflight.day !== day) saveState(cfg.stateDir, { ...st, inflight: { day, ref, done: 0 } });
  for (let i = done; i < batches.length; i++) {
    const tx = await pot.push(batches[i][0], batches[i][1], ref);
    await tx.wait();
    log(`pushed batch ${i + 1}/${batches.length} tx ${tx.hash}`);
    saveState(cfg.stateDir, { ...loadState(cfg.stateDir), inflight: { day, ref, done: i + 1 } });
  }
  const finalState: HolderState = {
    ledgerBlock: b1,
    balances: applyTransfers(st.balances, transfers),
    pending: res.pending,
    lastDay: day,
  };
  saveState(cfg.stateDir, finalState);
  return `paid ${entries.length} holders for ${day}`;
}
