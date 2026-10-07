// LOCAL TESTING ONLY: a fake drand relay for the anvil integration test (works with the test harness contract only).
import { createServer } from "node:http";
const port = Number(process.env.PORT ?? 8788);
createServer((req, res) => {
  const m = /\/public\/(\d+)$/.exec(req.url ?? "");
  if (!m) { res.writeHead(404); res.end(); return; }
  const round = BigInt(m[1]);
  const x = (round * 7919n + 12345n).toString(16).padStart(64, "0");
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ round: Number(round), signature: x + "0".repeat(64) }));
}).listen(port, () => console.log("mock drand on", port));
