/**
 * `bun scripts/db-fault.ts check`: reads DB_FAULT and prints what the staging Worker would read from it
 * (src/db/fault.ts parseDbFault), one line. Exits 1 when the value is neither `off` nor a fault the Worker takes, so
 * cmux-vm.yml's db-fault-staging never writes a value that would silently do nothing.
 */
import { parseDbFault } from "../src/db/fault.ts";

const [command] = process.argv.slice(2);
if (command !== "check") {
  console.error("usage: DB_FAULT=<json|off> bun scripts/db-fault.ts check");
  process.exit(2);
}
const value = process.env["DB_FAULT"] ?? "";
if (value.trim() === "off") {
  console.log("db fault: off");
} else {
  const fault = parseDbFault(value, "staging");
  if (fault === null) {
    console.error("db fault: refused (mode latency|stall, ms 1..60000, share (0,1], from < until epoch ms, window <= 1 h)");
    process.exit(1);
  }
  const at = (ms: number) => new Date(ms).toISOString();
  console.log(`db fault: ${fault.mode} ${fault.ms} ms on ${fault.share * 100}% of queries, ${at(fault.fromMs)} to ${at(fault.untilMs)}`);
}
