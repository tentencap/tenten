import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Balances, Pending } from "./holders.js";

export interface HolderState {
  ledgerBlock: number; // last block applied to `balances`
  balances: Balances;
  pending: Record<string, Pending>;
  lastDay: string; // last period that was paid, YYYY-MM-DD
  inflight?: { day: string; ref: string; done: number }; // batches already pushed for a period in progress
}

const ser = (_k: string, v: unknown) => (typeof v === "bigint" ? { __b: v.toString() } : v);
const de = (_k: string, v: unknown) =>
  v && typeof v === "object" && "__b" in (v as object) ? BigInt((v as { __b: string }).__b) : v;

export function loadState(dir: string): HolderState {
  const f = join(dir, "holders.json");
  if (!existsSync(f)) return { ledgerBlock: 0, balances: {}, pending: {}, lastDay: "" };
  return JSON.parse(readFileSync(f, "utf8"), de) as HolderState;
}

export function saveState(dir: string, s: HolderState): void {
  mkdirSync(dir, { recursive: true });
  const f = join(dir, "holders.json");
  writeFileSync(f + ".tmp", JSON.stringify(s, ser));
  renameSync(f + ".tmp", f);
}

export function writeJson(dir: string, name: string, obj: unknown): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), JSON.stringify(obj, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}
