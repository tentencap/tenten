import { describe, expect, it } from "vitest";
import { fetchBeacon, parseSignature } from "../src/drand.js";

const SIG = "2b47a71a0ed8a183a6db9f56b224818bb1ff31580eb5b4bdc379ac0f0a75a4dd2eddbd9b1be8baa32e5685a8fad974e6ee4693bf64d9b81242c45ead1be35597";

describe("drand", () => {
  it("splits a 64-byte signature into two words", () => {
    const [x, y] = parseSignature(SIG);
    expect(x).toBe(BigInt("0x" + SIG.slice(0, 64)));
    expect(y).toBe(BigInt("0x" + SIG.slice(64)));
    expect(() => parseSignature("abcd")).toThrow();
  });

  it("falls back to the next relay and checks the round", async () => {
    const calls: string[] = [];
    const f = (async (url: string) => {
      calls.push(url);
      if (url.startsWith("https://bad")) return { ok: false, status: 500, json: async () => ({}) };
      return { ok: true, status: 200, json: async () => ({ round: 42, signature: SIG }) };
    }) as unknown as typeof fetch;
    const out = await fetchBeacon(["https://bad", "https://good"], "hash", 42n, f);
    expect(out[0]).toBe(BigInt("0x" + SIG.slice(0, 64)));
    expect(calls).toHaveLength(2);
    await expect(fetchBeacon(["https://good"], "hash", 43n, f)).rejects.toThrow(/no drand relay/);
  });
});
