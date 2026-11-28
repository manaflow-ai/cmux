// Cold headless Chrome, the browser host's first calls, timed. Usage:
//   node scripts/cmux-next/bench-browser-first-call.mjs CHROME ROUNDS LOAD(0|1)
// Each round: drop caches when allowed, fresh profile, spawn Chrome with the host's default args over
// --remote-debugging-pipe, then send the host's set_up_browser calls in order (3x Browser.setPermission,
// Target.setDiscoverTargets) with a 60 s deadline each, and print one JSON line per round with each reply's ms.
// LOAD=1 runs 4 busy processes per core and 2 fsync writers for the whole run (the #44075 bench's load).
import { spawn, execSync } from "node:child_process";
import { mkdtempSync, rmSync, openSync, writeSync, fsyncSync, closeSync } from "node:fs";
import { tmpdir, cpus } from "node:os";
import { join } from "node:path";

const [chrome, roundsArg = "20", loadArg = "0"] = process.argv.slice(2);
const rounds = Number(roundsArg);
const loaders = [];
if (loadArg === "1") {
  for (let i = 0; i < cpus().length * 4; i++) loaders.push(spawn("sh", ["-c", "while :; do :; done"], { stdio: "ignore" }));
  const writer = `const fs=require("fs");const p=require("os").tmpdir()+"/fsync-"+process.pid;for(;;){const f=fs.openSync(p,"w");fs.writeSync(f,Buffer.alloc(1<<20));fs.fsyncSync(f);fs.closeSync(f);}`;
  for (let i = 0; i < 2; i++) loaders.push(spawn(process.execPath, ["-e", writer], { stdio: "ignore" }));
}
const stopLoad = () => loaders.forEach((p) => p.kill("SIGKILL"));
process.on("exit", stopLoad);

const args = (profile) => [
  "--headless", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
  "--disable-background-networking", "--disable-component-update", "--disable-sync",
  "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
  "--metrics-recording-only", "--password-store=basic", "--use-mock-keychain", "--hide-scrollbars",
  "--window-size=1280,800", "--mute-audio", "--disable-features=PaintHolding,HappyEyeballsV3", "about:blank",
];

function dropCaches() {
  try { execSync("sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null", { stdio: "ignore" }); return true; } catch { return false; }
}

async function round(n) {
  const cold = dropCaches();
  const profile = mkdtempSync(join(tmpdir(), "cdp-first-"));
  const t0 = performance.now();
  const child = spawn(chrome, args(profile), { stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"], detached: true });
  let stderr = "";
  child.stderr.on("data", (d) => { stderr += d; if (stderr.length > 4000) stderr = stderr.slice(-4000); });
  const write = child.stdio[3], read = child.stdio[4];
  const waiting = new Map();
  let buf = Buffer.alloc(0);
  read.on("data", (d) => {
    buf = Buffer.concat([buf, d]);
    let i;
    while ((i = buf.indexOf(0)) >= 0) {
      const msg = JSON.parse(buf.subarray(0, i).toString());
      buf = buf.subarray(i + 1);
      if (msg.id && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
    }
  });
  let id = 0;
  const call = (method, params) => new Promise((resolve) => {
    const my = ++id, start = performance.now();
    const timer = setTimeout(() => { waiting.delete(my); resolve({ method, ms: null, timeout: true }); }, 60000);
    waiting.set(my, (msg) => { clearTimeout(timer); resolve({ method, ms: Math.round(performance.now() - start), error: msg.error?.message }); });
    write.write(JSON.stringify({ id: my, method, params }) + "\0");
  });
  const calls = [];
  for (const permission of [{ name: "clipboard-read" }, { name: "clipboard-write" }, { name: "clipboard-write", allowWithoutSanitization: true }]) {
    calls.push(await call("Browser.setPermission", { permission, setting: "denied" }));
  }
  calls.push(await call("Target.setDiscoverTargets", { discover: true }));
  const total = Math.round(performance.now() - t0);
  // Chrome's zygote and renderers outlive its main process: kill the whole group, then remove the profile.
  const exited = new Promise((r) => child.once("exit", r));
  try { process.kill(-child.pid, "SIGKILL"); } catch {}
  await exited;
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); } catch {}
  const first = calls[0].ms;
  console.log(JSON.stringify({ round: n, cold, load: loadArg === "1", first_ms: first, over_10s: first === null || first > 10000, total_ms: total, calls,
    stderr: first === null || first > 10000 ? stderr.slice(-600) : undefined }));
  return first;
}

const firsts = [];
for (let n = 1; n <= rounds; n++) firsts.push(await round(n));
const sorted = firsts.map((v) => v ?? 60000).sort((a, b) => a - b);
const q = (p) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
console.log(JSON.stringify({ summary: true, load: loadArg === "1", rounds, over_10s: firsts.filter((v) => v === null || v > 10000).length,
  p50: q(0.5), p90: q(0.9), max: sorted[sorted.length - 1] }));
stopLoad();
process.exit(0);
