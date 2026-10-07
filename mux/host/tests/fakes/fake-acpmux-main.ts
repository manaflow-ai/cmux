// `acpmux daemon run --ready-fd N` stand-in for the CLI test: serves FakeAcpmux
// on $ACPMUX_SOCKET, then (as the real acpmux) writes one ready line to fd N and
// its pid to $ACPMUX_HOME/fake.pid. Without --ready-fd it refuses to start.
import { closeSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { FakeAcpmux } from "./fake-acpmux.ts";

const [command, sub, flag, fdText] = process.argv.slice(2);
if (command !== "daemon" || sub !== "run" || flag !== "--ready-fd" || !/^\d+$/.test(fdText ?? "")) process.exit(2);
const fake = new FakeAcpmux(process.env.ACPMUX_SOCKET!);
await fake.start();
writeFileSync(join(process.env.ACPMUX_HOME!, "fake.pid"), String(process.pid));
const fd = Number(fdText);
writeSync(fd, `${JSON.stringify({ pid: process.pid, socket: process.env.ACPMUX_SOCKET })}\n`);
closeSync(fd);
console.log("fake acpmux ready");
process.on("SIGTERM", () => void fake.stop().then(() => process.exit(0)));
