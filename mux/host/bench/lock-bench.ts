// Times the MUX_HOME lock: a free acquire+release (the host start path) and a
// refused acquire while a live process holds it (the stale-check path).
// Run: bun host/bench/lock-bench.ts
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { takeLock } from "../src/lock.ts";

const dir = mkdtempSync(join(tmpdir(), "mux-lock-bench-"));
const path = join(dir, "host.lock");
const runs = 200;
const time = (label: string, body: () => void) => {
  const start = performance.now();
  for (let i = 0; i < runs; i++) body();
  console.log(`${label}: ${((performance.now() - start) / runs).toFixed(3)} ms per call`);
};
time("free acquire+release", () => takeLock(path)?.());
const other = spawn("sleep", ["30"], { stdio: "ignore" });
writeFileSync(path, `${other.pid}\n${Math.round(performance.timeOrigin)}\n`);
time("refused (live holder, stale check)", () => takeLock(path));
other.kill("SIGKILL");
rmSync(dir, { recursive: true, force: true });
