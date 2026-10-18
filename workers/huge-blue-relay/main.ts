import { authorizeHugeBlueAttachToken } from "../../web/services/vms/hugeBlueAttachTokens";
import { startHugeBlueRelay } from "./server";

const hostId = process.env.HUGE_BLUE_VM_ID;
const session = process.env.HUGE_BLUE_CMUX_REMOTE_SESSION;
if (!hostId || !session) throw new Error("relay host/session identity required");
const relay = startHugeBlueRelay({
  port: Number(process.env.CMUX_RELAY_PORT ?? 1338),
  upstream: "ws://127.0.0.1:1337/v1/link",
  authorize: (token) => authorizeHugeBlueAttachToken(token, { hostId, session }),
});
console.log(JSON.stringify({ event: "relay_ready", port: relay.server.port, hostId, session, sha: process.env.CMUX_SOURCE_SHA }));
for (const signal of ["SIGTERM", "SIGINT"] as const) process.once(signal, async () => {
  await relay.stop();
  process.exit(0);
});
