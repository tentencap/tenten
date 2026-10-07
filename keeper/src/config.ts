// Configuration is read from the environment. The private key is read ONLY from the environment
// (KEEPER_PRIVATE_KEY) and never written anywhere. Without a key the keeper runs read-only.
export interface Config {
  rpcUrl: string;
  chainId: number;
  game: string;
  pot: string;
  tenV1: string;
  tenV1GenesisBlock: number;
  poolEthUsdg: string;
  keeperKey?: string;
  dryRun: boolean;
  drandChainHash: string;
  drandRelays: string[];
  stateDir: string;
  minPayoutUsd: number;
  expiryDays: number;
  payoutHourUtc: number;
  pollMs: number;
  minKeeperEth: number;
  sweepThresholdEth: number;
  alertWebhook?: string;
  logRange: number;
}

function req(env: NodeJS.ProcessEnv, k: string): string {
  const v = env[k];
  if (!v) throw new Error(`missing environment variable ${k}`);
  return v;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    rpcUrl: env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com",
    chainId: Number(env.CHAIN_ID ?? 4663),
    game: req(env, "GAME"),
    pot: req(env, "POT"),
    tenV1: env.TEN_V1 ?? "0xC4F021c73A5b6fFae6C43515f0a4BbF615B31c7b",
    tenV1GenesisBlock: Number(env.TEN_V1_GENESIS_BLOCK ?? 63667259),
    poolEthUsdg: env.POOL_ETH_USDG ?? "0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca",
    keeperKey: env.KEEPER_PRIVATE_KEY || undefined,
    dryRun: env.DRY_RUN === "1" || !env.KEEPER_PRIVATE_KEY,
    drandChainHash: env.DRAND_CHAIN_HASH ?? "04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3",
    drandRelays: (env.DRAND_RELAYS ?? "https://api.drand.sh,https://api2.drand.sh,https://api3.drand.sh,https://drand.cloudflare.com").split(","),
    stateDir: env.STATE_DIR ?? "./state",
    minPayoutUsd: Number(env.MIN_PAYOUT_USD ?? 0.25),
    expiryDays: Number(env.EXPIRY_DAYS ?? 90),
    payoutHourUtc: Number(env.PAYOUT_HOUR_UTC ?? 12),
    pollMs: Number(env.POLL_MS ?? 20000),
    minKeeperEth: Number(env.MIN_KEEPER_ETH ?? 0.005),
    sweepThresholdEth: Number(env.SWEEP_THRESHOLD_ETH ?? 0.01),
    alertWebhook: env.ALERT_WEBHOOK || undefined,
    logRange: Number(env.LOG_RANGE ?? 40000),
  };
}
