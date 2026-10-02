// `acpmux daemon run` stand-in for the CLI test: serves FakeAcpmux on
// $ACPMUX_SOCKET and writes its pid to $ACPMUX_HOME/fake.pid.
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { FakeAcpmux } from "./fake-acpmux.ts";

if (process.argv[2] !== "daemon" || process.argv[3] !== "run") process.exit(2);
writeFileSync(join(process.env.ACPMUX_HOME!, "fake.pid"), String(process.pid));
const fake = new FakeAcpmux(process.env.ACPMUX_SOCKET!);
await fake.start();
console.log("fake acpmux ready");
process.on("SIGTERM", () => void fake.stop().then(() => process.exit(0)));
