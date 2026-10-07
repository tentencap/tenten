import { Contract, JsonRpcProvider, Wallet, formatEther } from "ethers";
import { readFileSync } from "node:fs";
import { loadConfig } from "./config.js";
import { gameCycle, type Ctx } from "./gameKeeper.js";
import { advanceLedger, holdersRun } from "./holdersRun.js";
import { writeJson, loadState } from "./state.js";
import gameAbi from "./abi/TenBlocks.json" with { type: "json" };

const potAbi = JSON.parse(readFileSync(new URL("./abi/HolderPot.json", import.meta.url), "utf8")) as string[];

async function alert(url: string | undefined, text: string): Promise<void> {
  console.log(`ALERT ${text}`);
  try {
    const token = process.env.TELEGRAM_BOT_TOKEN;
    const chat = process.env.TELEGRAM_CHAT_ID;
    if (token && chat) {
      await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ chat_id: chat, text: `TenBlocks keeper: ${text}` }),
      });
    } else if (url) {
      await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text }) });
    }
  } catch {
    /* alerting must never stop the keeper */
  }
}

async function main(): Promise<void> {
  const cfg = loadConfig();
  const args = new Set(process.argv.slice(2));
  const provider = new JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
  const signer = cfg.keeperKey ? new Wallet(cfg.keeperKey, provider) : undefined;
  const log = (m: string) => console.log(`${new Date().toISOString()} ${m}`);
  const game = new Contract(cfg.game, gameAbi, signer ?? provider);
  const pot = new Contract(cfg.pot, potAbi, signer ?? provider);
  const ctx: Ctx = { cfg, provider, signer, game, pot, log };
  log(`keeper start: ${cfg.dryRun ? "DRY RUN (nothing is sent)" : "live"}; game ${cfg.game}; pot ${cfg.pot}; wallet ${signer?.address ?? "none"}`);

  if (args.has("--bootstrap")) {
    const head = await provider.getBlockNumber();
    const st = await advanceLedger(provider, cfg, loadState(cfg.stateDir), head);
    log(`ledger up to block ${st.ledgerBlock} (${Object.keys(st.balances).length} addresses)`);
    return;
  }

  let lastAlert = 0;
  let lastHoldersAlert = 0;
  const lastOk = { resolve: Date.now() };
  for (;;) {
    const status: Record<string, unknown> = { time: new Date().toISOString(), dryRun: cfg.dryRun };
    try {
      const rep = await gameCycle(ctx);
      status.cycle = rep;
      if (rep.errors.length) await alert(cfg.alertWebhook, `keeper errors: ${rep.errors.join(" | ")}`);
      if (rep.resolved) lastOk.resolve = Date.now();
      if (signer) {
        const eth = Number(formatEther(await provider.getBalance(signer.address)));
        status.keeperEth = eth;
        if (eth < cfg.minKeeperEth && Date.now() - lastAlert > 6 * 3600_000) {
          lastAlert = Date.now();
          await alert(cfg.alertWebhook, `keeper wallet low on ETH: ${eth}`);
        }
      }
    } catch (e) {
      status.error = String((e as Error).message ?? e);
      await alert(cfg.alertWebhook, `keeper cycle failed: ${status.error}`);
    }
    // The daily holders run is independent of the game cycle: its failures must not look like a game failure,
    // and a persistent one (for example the oracle history is still too short) alerts at most every 6 hours.
    try {
      status.holders = await holdersRun(cfg, provider, game, pot, log);
    } catch (e) {
      status.holdersError = String((e as Error).message ?? e);
      if (Date.now() - lastHoldersAlert > 6 * 3600_000) {
        lastHoldersAlert = Date.now();
        await alert(cfg.alertWebhook, `holders run failed (will retry): ${status.holdersError}`);
      }
    }
    writeJson(cfg.stateDir, "status.json", status);
    if (args.has("--once")) return;
    await new Promise((r) => setTimeout(r, cfg.pollMs));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
