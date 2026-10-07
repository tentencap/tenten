// Game keeper: everything here is permissionless on chain. The wallet only needs ETH for gas (and it receives resolver tips).
import { Contract, JsonRpcProvider, Wallet } from "ethers";
import type { Config } from "./config.js";
import { fetchBeacon } from "./drand.js";

export interface Ctx {
  cfg: Config;
  provider: JsonRpcProvider;
  signer?: Wallet;
  game: Contract; // connected to the signer when there is one
  pot: Contract;
  log: (m: string) => void;
}

export interface CycleReport {
  resolved: number;
  skipped: number;
  sent: string[];
  errors: string[];
}

function why(e: unknown): string {
  const x = e as { shortMessage?: string; reason?: string; message?: string; revert?: { name?: string } };
  const name = x.revert?.name ? ` (${x.revert.name})` : "";
  return (x.shortMessage ?? x.reason ?? x.message ?? String(e)) + name;
}

/** Simulate first; send only if the call would succeed. In dry mode nothing is sent. */
export async function attempt(ctx: Ctx, rep: CycleReport, label: string, method: string, args: unknown[]): Promise<boolean> {
  try {
    await ctx.game.getFunction(method).staticCall(...args);
  } catch (e) {
    ctx.log(`skip ${label}: ${why(e)}`);
    return false;
  }
  if (ctx.cfg.dryRun || !ctx.signer) {
    ctx.log(`[dry] would send ${label}`);
    rep.sent.push(`dry:${label}`);
    return true;
  }
  try {
    const tx = await ctx.game.getFunction(method)(...args);
    const rc = await tx.wait();
    ctx.log(`sent ${label} tx ${tx.hash} gas ${rc?.gasUsed}`);
    rep.sent.push(label);
    return true;
  } catch (e) {
    rep.errors.push(`${label}: ${why(e)}`);
    ctx.log(`error ${label}: ${why(e)}`);
    return false;
  }
}

/** Unresolved rounds with deposits, oldest first, found by walking back from the last deposited round. */
export async function pendingRounds(ctx: Ctx): Promise<bigint[]> {
  const [exists, last] = (await ctx.game.lastDepositedRound()) as [boolean, bigint];
  if (!exists) return [];
  const out: bigint[] = [];
  let r = last;
  for (let i = 0; i < 2000; i++) {
    const R = await ctx.game.getRound(r);
    if (BigInt(R.status) !== 1n) break;
    out.push(r);
    if (BigInt(R.prevPlus1) === 0n) break;
    r = BigInt(R.prevPlus1) - 1n;
  }
  return out.reverse();
}

export async function resolveCycle(ctx: Ctx, rep: CycleReport): Promise<void> {
  const now = BigInt((await ctx.provider.getBlock("latest"))!.timestamp);
  const refundTimeout = BigInt(await ctx.game.REFUND_TIMEOUT());
  const ready: bigint[] = [];
  for (const r of await pendingRounds(ctx)) {
    const unlock = BigInt(await ctx.game.beaconUnlock(r));
    if (now < unlock) break; // later rounds unlock later still
    if (now >= unlock + refundTimeout) {
      if (await attempt(ctx, rep, `skipRefundable(${r})`, "skipRefundable", [r])) rep.skipped++;
      continue;
    }
    ready.push(r);
  }
  for (let i = 0; i < ready.length; i += 16) {
    const batch = ready.slice(i, i + 16);
    let sigs: [bigint, bigint][];
    try {
      sigs = await Promise.all(
        batch.map(async (r) => fetchBeacon(ctx.cfg.drandRelays, ctx.cfg.drandChainHash, BigInt(await ctx.game.drandRound(r)))),
      );
    } catch (e) {
      rep.errors.push(`drand: ${why(e)}`);
      ctx.log(`drand unavailable: ${why(e)}`);
      return;
    }
    if (await attempt(ctx, rep, `resolveMany([${batch.join(",")}])`, "resolveMany", [batch, sigs])) rep.resolved += batch.length;
    else return; // order matters: do not try later batches
  }
}

export async function housekeeping(ctx: Ctx, rep: CycleReport): Promise<void> {
  const g = ctx.game;
  const now = BigInt((await ctx.provider.getBlock("latest"))!.timestamp);
  if (BigInt(await g.holdersEthPending()) > 0n) await attempt(ctx, rep, "feedHolders", "feedHolders", []);
  await attempt(ctx, rep, "closeEpoch", "closeEpoch", []);

  const n = Number(await g.epochCount());
  const start = Number(await g.nextToConvert());
  const conversionTimeout = BigInt(await g.CONVERSION_TIMEOUT());
  let converted = 0;
  for (let i = start; i < n && converted < 4; i++) {
    const e = await g.getEpoch(i);
    if (Number(e.state) !== 1) continue; // only closed epochs
    const ok = await attempt(ctx, rep, `convertEpoch(${i})`, "convertEpoch", [i]);
    if (ok) converted++;
    else if (now >= BigInt(e.closedAt) + conversionTimeout) await attempt(ctx, rep, `releaseEpoch(${i})`, "releaseEpoch", [i]);
  }

  await attempt(ctx, rep, "releaseCarry", "releaseCarry", []);
  if (BigInt(await g.holdersOwed()) > 0n) await attempt(ctx, rep, "flushHolders", "flushHolders", []);
  await attempt(ctx, rep, "sweepPayload", "sweepPayload", []);
  const threshold = BigInt(Math.floor(ctx.cfg.sweepThresholdEth * 1e18));
  if (BigInt(await g.opsAccrued()) >= threshold) await attempt(ctx, rep, "sweepOps", "sweepOps", []);
  if (BigInt(await g.buybackAccrued()) >= threshold) await attempt(ctx, rep, "sweepBuyback", "sweepBuyback", []);
}

export async function gameCycle(ctx: Ctx): Promise<CycleReport> {
  const rep: CycleReport = { resolved: 0, skipped: 0, sent: [], errors: [] };
  try {
    await resolveCycle(ctx, rep);
  } catch (e) {
    rep.errors.push(`resolve: ${why(e)}`);
  }
  try {
    await housekeeping(ctx, rep);
  } catch (e) {
    rep.errors.push(`housekeeping: ${why(e)}`);
  }
  return rep;
}
