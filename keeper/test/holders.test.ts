import { describe, expect, it } from "vitest";
import { allocate, applyTransfers, computeTwab, minPayoutWei, period, settle, snapshotHash, type Transfer } from "../src/holders.js";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";
const Z = "0x0000000000000000000000000000000000000000";
const e18 = 10n ** 18n;
const T0 = 1_000_000;
const T1 = T0 + 86400;
const t = (block: number, from: string, to: string, v: bigint, logIndex = 0): Transfer => ({ block, logIndex, from, to, value: v });

describe("time-weighted balance", () => {
  it("a holder for the whole day gets balance x 86400", () => {
    const tw = computeTwab({ [A]: 100n * e18 }, [], () => T0, T0, T1);
    expect(tw[A]).toBe(100n * e18 * 86400n);
  });

  it("buying at mid-day earns half; selling just after the snapshot earns nothing extra", () => {
    const mid = T0 + 43200;
    const tw = computeTwab({ [A]: 100n * e18 }, [t(10, A, B, 100n * e18)], () => mid, T0, T1);
    expect(tw[A]).toBe(100n * e18 * 43200n); // A held for half the day
    expect(tw[B]).toBe(100n * e18 * 43200n); // B for the other half
  });

  it("a buy one second before the end counts for one second", () => {
    const tw = computeTwab({ [A]: 100n * e18 }, [t(10, A, B, 100n * e18)], () => T1 - 1, T0, T1);
    expect(tw[B]).toBe(100n * e18);
  });

  it("mints and burns involve the zero address and are not tracked", () => {
    const tw = computeTwab({}, [t(1, Z, A, 10n * e18)], () => T0 + 86400 / 2, T0, T1);
    expect(tw[A]).toBe(10n * e18 * 43200n);
    expect(tw[Z]).toBeUndefined();
  });

  it("ledger replay matches", () => {
    const b = applyTransfers({ [A]: 50n }, [t(1, A, B, 20n), t(2, B, C, 5n)]);
    expect(b[A]).toBe(30n);
    expect(b[B]).toBe(15n);
    expect(b[C]).toBe(5n);
  });
});

describe("allocation", () => {
  it("shares pro rata, never more than the pot, and skips excluded addresses", () => {
    const twab = { [A]: 3n, [B]: 1n, [C]: 6n };
    const out = allocate(twab, new Set([C]), 1000n);
    expect(out[A]).toBe(750n);
    expect(out[B]).toBe(250n);
    expect(out[C]).toBeUndefined();
    expect(Object.values(out).reduce((x, y) => x + y, 0n)).toBeLessThanOrEqual(1000n);
  });

  it("floors: the sum can be below the pot but never above", () => {
    const out = allocate({ [A]: 1n, [B]: 1n, [C]: 1n }, new Set(), 100n);
    expect(Object.values(out).reduce((x, y) => x + y, 0n)).toBe(99n);
  });

  it("nothing to share gives nothing", () => {
    expect(allocate({}, new Set(), 100n)).toEqual({});
    expect(allocate({ [A]: 1n }, new Set([A]), 100n)).toEqual({});
  });
});

describe("minimum payout, carry and expiry", () => {
  const min = 5n * e18 / 100n; // 0.05 wsNET
  it("pays at or above the minimum and carries the rest", () => {
    const r = settle({}, { [A]: min, [B]: min - 1n }, min, 1000, 90 * 86400);
    expect(r.payments[A]).toBe(min);
    expect(r.payments[B]).toBeUndefined();
    expect(r.pending[B].amount).toBe(min - 1n);
  });

  it("carried amounts add up across days until they reach the minimum", () => {
    let p = settle({}, { [B]: min / 2n }, min, 1000, 90 * 86400);
    expect(p.payments[B]).toBeUndefined();
    p = settle(p.pending, { [B]: min / 2n }, min, 1000 + 86400, 90 * 86400);
    expect(p.payments[B]).toBe(min);
    expect(p.pending[B]).toBeUndefined();
  });

  it("an amount carried for more than 90 days expires back to the pot", () => {
    const old = { [B]: { amount: 7n, since: 0 } };
    const r = settle(old, {}, min, 91 * 86400, 90 * 86400);
    expect(r.expiredTotal).toBe(7n);
    expect(r.pending[B]).toBeUndefined();
    expect(r.payments[B]).toBeUndefined();
  });

  it("the final run pays everything, however small", () => {
    const r = settle({ [B]: { amount: 3n, since: 0 } }, { [A]: 2n }, min, 10, 90 * 86400, true);
    expect(r.payments[A]).toBe(2n);
    expect(r.payments[B]).toBe(3n);
    expect(r.pending).toEqual({});
  });

  it("the USD minimum converts to wsNET wei", () => {
    // ETH $2,700 and 2.7 wsNET per ETH -> wsNET = $1,000 -> $0.25 = 0.00025 wsNET
    const w = minPayoutWei(0.25, 2700, 27n * e18 / 10n);
    expect(w).toBe(250_000_000_000_000n);
    expect(() => minPayoutWei(0.25, 0, e18)).toThrow();
  });
});

describe("period and hash", () => {
  it("the period closes at the last 12:00 UTC", () => {
    const now = Date.UTC(2026, 9, 6, 13, 0, 0) / 1000; // 13:00 on Oct 6
    const p = period(now, 12);
    expect(p.t1).toBe(Date.UTC(2026, 9, 6, 12, 0, 0) / 1000);
    expect(p.day).toBe("2026-10-06");
    const before = Date.UTC(2026, 9, 6, 11, 59, 0) / 1000;
    expect(period(before, 12).day).toBe("2026-10-05");
  });

  it("the snapshot hash is deterministic and sensitive", () => {
    expect(snapshotHash({ a: 1n })).toBe(snapshotHash({ a: 1n }));
    expect(snapshotHash({ a: 1n })).not.toBe(snapshotHash({ a: 2n }));
  });
});
