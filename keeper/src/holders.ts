// Daily rewards for TEN v1 holders (docs/HOLDER_RULES.md). The pure functions at the top have no I/O and are tested;
// the I/O functions at the bottom scan Transfer events and push payments through HolderPot.
import { createHash } from "node:crypto";

export interface Transfer {
  block: number;
  logIndex: number;
  from: string;
  to: string;
  value: bigint;
}

export type Balances = Record<string, bigint>;

const lc = (a: string) => a.toLowerCase();
const ZERO = "0x0000000000000000000000000000000000000000";

/** Apply transfers (sorted) to balances; mints and burns involve the zero address, which is not tracked. */
export function applyTransfers(balances: Balances, transfers: Transfer[]): Balances {
  const b: Balances = { ...balances };
  for (const t of transfers) {
    const from = lc(t.from);
    const to = lc(t.to);
    if (from !== ZERO) b[from] = (b[from] ?? 0n) - t.value;
    if (to !== ZERO) b[to] = (b[to] ?? 0n) + t.value;
  }
  return b;
}

export function sortTransfers(ts: Transfer[]): Transfer[] {
  return [...ts].sort((x, y) => x.block - y.block || x.logIndex - y.logIndex);
}

/**
 * Time-weighted balance over [t0, t1]: the integral of each address's balance over time (balance x seconds).
 * `startBalances` are the balances at t0; `transfers` are those inside (t0, t1], sorted; `timeOf` gives a block's timestamp.
 */
export function computeTwab(
  startBalances: Balances,
  transfers: Transfer[],
  timeOf: (block: number) => number,
  t0: number,
  t1: number,
): Record<string, bigint> {
  const bal: Balances = { ...startBalances };
  const last: Record<string, number> = {};
  const area: Record<string, bigint> = {};
  const touch = (addr: string, now: number) => {
    const b = bal[addr] ?? 0n;
    const from = last[addr] ?? t0;
    if (b > 0n && now > from) area[addr] = (area[addr] ?? 0n) + b * BigInt(now - from);
    last[addr] = now;
  };
  for (const t of sortTransfers(transfers)) {
    const now = Math.min(Math.max(timeOf(t.block), t0), t1);
    const from = lc(t.from);
    const to = lc(t.to);
    if (from !== ZERO) {
      touch(from, now);
      bal[from] = (bal[from] ?? 0n) - t.value;
    }
    if (to !== ZERO) {
      touch(to, now);
      bal[to] = (bal[to] ?? 0n) + t.value;
    }
  }
  for (const addr of Object.keys(bal)) touch(addr, t1);
  return area;
}

/** Share the new money pro rata to the time-weighted balance, excluding the given addresses. Floors; the remainder stays in the pot. */
export function allocate(twab: Record<string, bigint>, excluded: Set<string>, money: bigint): Record<string, bigint> {
  let total = 0n;
  for (const [a, v] of Object.entries(twab)) if (!excluded.has(lc(a)) && v > 0n) total += v;
  const out: Record<string, bigint> = {};
  if (total === 0n || money <= 0n) return out;
  for (const [a, v] of Object.entries(twab)) {
    if (excluded.has(lc(a)) || v <= 0n) continue;
    const amt = (money * v) / total;
    if (amt > 0n) out[lc(a)] = amt;
  }
  return out;
}

export interface Pending {
  amount: bigint;
  since: number; // unix seconds of the oldest amount in the carried balance
}

export interface SettleResult {
  payments: Record<string, bigint>;
  pending: Record<string, Pending>;
  expiredTotal: bigint;
}

/**
 * Add today's amounts to what was carried; pay holders whose total reaches the minimum; carry the rest.
 * Carried amounts older than `expirySec` are dropped (they go back to the pot and are shared again). When `final` is
 * true everything is paid, whatever its size (the closing run).
 */
export function settle(
  pending: Record<string, Pending>,
  today: Record<string, bigint>,
  minWei: bigint,
  now: number,
  expirySec: number,
  final = false,
): SettleResult {
  const next: Record<string, Pending> = {};
  let expiredTotal = 0n;
  for (const [a, p] of Object.entries(pending)) {
    if (!final && now - p.since > expirySec) expiredTotal += p.amount;
    else next[a] = { ...p };
  }
  for (const [a, amt] of Object.entries(today)) {
    const cur = next[a];
    next[a] = cur ? { amount: cur.amount + amt, since: cur.since } : { amount: amt, since: now };
  }
  const payments: Record<string, bigint> = {};
  const carried: Record<string, Pending> = {};
  for (const [a, p] of Object.entries(next)) {
    if (final || p.amount >= minWei) payments[a] = p.amount;
    else carried[a] = p;
  }
  return { payments, pending: carried, expiredTotal };
}

/** The minimum payout in wsNET wei for a USD minimum, given ETH/USD and the wsNET amount per 1 ETH. */
export function minPayoutWei(minUsd: number, ethUsd: number, wsPerEthWei: bigint): bigint {
  if (!(ethUsd > 0) || wsPerEthWei <= 0n) throw new Error("price unavailable");
  const wsUsd = ethUsd / (Number(wsPerEthWei) / 1e18); // USD per 1 wsNET
  return BigInt(Math.ceil((minUsd / wsUsd) * 1e18));
}

export function snapshotHash(obj: unknown): string {
  const canonical = JSON.stringify(obj, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
  return "0x" + createHash("sha256").update(canonical).digest("hex");
}

/** The period that closes at the last `hourUtc`:00 UTC at or before `now`. */
export function period(now: number, hourUtc: number): { t0: number; t1: number; day: string } {
  const d = new Date(now * 1000);
  let t1 = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), hourUtc) / 1000;
  if (t1 > now) t1 -= 86400;
  const day = new Date(t1 * 1000).toISOString().slice(0, 10);
  return { t0: t1 - 86400, t1, day };
}
