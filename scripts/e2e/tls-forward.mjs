// TLS front for the iOS e2e per-run backend (scripts/e2e/backend-up.sh).
//
// Terminates TLS with the fixed-name backend certificate on the runner's
// tailnet address and forwards each connection's bytes to a loopback service.
// It forwards TCP, not HTTP, so WebSocket upgrades (iroh-v2 control socket,
// presence subscriptions) and the Iroh relay protocol pass through unchanged.
//
// Usage: node tls-forward.mjs <bind-address> <cert.pem> <key.pem> <listen>:<target> ...
import { readFileSync } from "node:fs";
import net from "node:net";
import tls from "node:tls";

const [bindAddress, certPath, keyPath, ...routes] = process.argv.slice(2);
if (!bindAddress || !certPath || !keyPath || routes.length === 0) {
  console.error("usage: tls-forward.mjs <bind-address> <cert.pem> <key.pem> <listen>:<target> ...");
  process.exit(2);
}
const credentials = { cert: readFileSync(certPath), key: readFileSync(keyPath) };

for (const route of routes) {
  const [listenPort, targetPort] = route.split(":").map(Number);
  const server = tls.createServer(credentials, (client) => {
    const upstream = net.connect({ host: "127.0.0.1", port: targetPort });
    client.pipe(upstream).pipe(client);
    const close = () => {
      client.destroy();
      upstream.destroy();
    };
    client.on("error", close);
    upstream.on("error", close);
  });
  server.on("tlsClientError", () => {});
  server.listen(listenPort, bindAddress, () => {
    console.log(`tls-forward: ${bindAddress}:${listenPort} -> 127.0.0.1:${targetPort}`);
  });
}
