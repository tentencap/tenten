// The drand evmnet beacon for a round: the signature is the only input the contract needs.
export function parseSignature(hex: string): [bigint, bigint] {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (!/^[0-9a-fA-F]{128}$/.test(h)) throw new Error("drand signature must be 128 hex characters");
  return [BigInt("0x" + h.slice(0, 64)), BigInt("0x" + h.slice(64))];
}

export async function fetchBeacon(
  relays: string[],
  chainHash: string,
  round: bigint,
  fetchImpl: typeof fetch = fetch,
): Promise<[bigint, bigint]> {
  let lastErr: unknown;
  for (const relay of relays) {
    try {
      const res = await fetchImpl(`${relay}/${chainHash}/public/${round}`, { signal: AbortSignal.timeout(8000) });
      if (!res.ok) throw new Error(`${relay} answered ${res.status}`);
      const j = (await res.json()) as { round: number | string; signature: string };
      if (BigInt(j.round) !== round) throw new Error(`${relay} returned round ${j.round}, wanted ${round}`);
      return parseSignature(j.signature);
    } catch (e) {
      lastErr = e;
    }
  }
  throw new Error(`no drand relay could give round ${round}: ${String(lastErr)}`);
}
