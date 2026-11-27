#!/usr/bin/env node
// The agent pane's load-and-evaluate time before its handshake: loads a built pane page
// (scripts/cmux-next/build-agent-pane-web.sh --out DIR) in headless Chrome with the CPU throttled,
// stubs the app's `agentSession` bridge (the handshake is asked and never answered, so nothing past
// it runs), and reports the page's `acpmux:handshakeStart` user-timing mark (perf.ts `markLaunch`,
// what the relaunch bench reads as page.origin -> page.handshakeStart) over N runs. With --profile it
// also samples the CPU up to that mark and prints the source files with the most self time, named
// through the bundle's chunks/frame-sites.js.
//
//   node scripts/measure/pane-handshake-eval.mjs --dir DIR [--dir DIR2 ...] [--runs 10] [--cpu 1,4] [--profile [--profile-runs N]]
//   CHROME=/path/to/chrome-headless-shell (default: ~/.cache/cmux-ci/chrome-headless-shell-*/...)
//
// Prints one "PANE-HANDSHAKE dir=... cpu=Nx runs=N median=... p10=... p90=... min=... max=..." line per
// directory and rate, dirs interleaved run by run so a busy host weighs on each the same.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, "../../webviews/package.json"));
const { chromium } = require("playwright-core");

const args = process.argv.slice(2);
const dirs = [];
let runs = 10;
let rates = [1, 4];
let profile = false;
/// Profiled runs per dir and rate: the PANE-EVAL medians are over these.
let profileRuns = 1;
let top = 25;
let saveProfile;
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--dir") dirs.push(path.resolve(args[++i]));
  else if (arg === "--runs") runs = Number(args[++i]);
  else if (arg === "--cpu") rates = args[++i].split(",").map(Number);
  else if (arg === "--profile") profile = true;
  else if (arg === "--profile-runs") profileRuns = Number(args[++i]);
  else if (arg === "--top") top = Number(args[++i]);
  else if (arg === "--save-profile") saveProfile = path.resolve(args[++i]);
  else {
    console.error(`usage: pane-handshake-eval.mjs --dir DIR [--dir DIR2] [--runs N] [--cpu 1,4] [--profile] [--profile-runs N] [--top N]`);
    process.exit(2);
  }
}
if (dirs.length === 0) {
  console.error("pane-handshake-eval: --dir names a built pane (build-agent-pane-web.sh --out DIR)");
  process.exit(2);
}

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const cache = path.join(os.homedir(), ".cache/cmux-ci");
  for (const name of fs.existsSync(cache) ? fs.readdirSync(cache).sort().reverse() : []) {
    const bin = path.join(cache, name, "chrome-headless-shell-linux64/chrome-headless-shell");
    if (name.startsWith("chrome-headless-shell") && fs.existsSync(bin)) return bin;
  }
  return undefined; // playwright's own
}

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };
function serve(dir) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    // The host's per-page snapshot script: none served, as on a chat with no saved copy.
    if (url.pathname === "/__harness-blank") {
      res.writeHead(200, { "content-type": "text/html" });
      res.end("<!doctype html><title>blank</title>");
      return;
    }
    if (url.pathname.endsWith("/__snapshot/chat.js")) {
      res.writeHead(200, { "content-type": "text/javascript", "cache-control": "no-store" });
      res.end("");
      return;
    }
    const file = path.join(dir, decodeURIComponent(url.pathname === "/" ? "/index.html" : url.pathname));
    if (!file.startsWith(dir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] ?? "application/octet-stream" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

// The app's bridge: every call but the handshake answers empty; the handshake (early or not) stays
// unanswered, so the page stops at handshakeStart and nothing past it costs the run.
const BRIDGE = `(() => {
  const pending = () => new Promise(() => {});
  window.webkit = { messageHandlers: { agentSession: { postMessage(body) {
    const method = body && body.method;
    if (method === "ready" || method === "transport.open") return pending();
    return Promise.resolve({ ok: true, value: {} });
  } } } };
})();`;

const PROFILE_TO_HANDSHAKE = `(() => {
  if (location.pathname.startsWith("/__harness")) return;
  console.profile("pane");
  new PerformanceObserver((list, observer) => {
    if (!list.getEntries().some((entry) => entry.name === "acpmux:handshakeStart")) return;
    observer.disconnect();
    console.profileEnd("pane");
  }).observe({ type: "mark", buffered: true });
})();`;

async function frameSites(dir) {
  const file = path.join(dir, "chunks/frame-sites.js");
  if (!fs.existsSync(file)) return undefined;
  return (await import(`${pathToFileURL(file).href}?t=${Date.now()}`)).default;
}

/// The source file behind a 0-based line/column of `script` (a key of the sites table).
function siteOf(sites, script, line, column) {
  const marks = sites?.files?.[script];
  if (!marks) return script;
  let lo = 0;
  let hi = marks.length / 3 - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const l = marks[mid * 3];
    const c = marks[mid * 3 + 1];
    if (l < line || (l === line && c <= column)) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found < 0 ? script : sites.sources[marks[found * 3 + 2]];
}

async function oneRun(browser, base, rate, withProfile) {
  const context = await browser.newContext({ viewport: { width: 900, height: 760 } });
  const page = await context.newPage();
  await page.addInitScript(BRIDGE);
  const cdp = await context.newCDPSession(page);
  await cdp.send("Network.enable");
  await cdp.send("Network.setCacheDisabled", { cacheDisabled: false });
  await cdp.send("Emulation.setCPUThrottlingRate", { rate });
  // A same-origin page first, so the pane loads in the renderer the profiler is attached to.
  await page.goto(`${base}/__harness-blank`, { waitUntil: "load" });
  let profiled;
  if (withProfile) {
    // The page starts the profile as the document begins and ends it at the handshake mark
    // (console.profile; PROFILE_TO_HANDSHAKE), so it holds exactly origin -> handshakeStart.
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
    profiled = new Promise((resolve) => cdp.on("Profiler.consoleProfileFinished", (event) => resolve(event.profile)));
    await page.addInitScript(PROFILE_TO_HANDSHAKE);
  }
  await page.goto(`${base}/index.html`, { waitUntil: "commit" });
  const handle = await page.waitForFunction(
    () => {
      const mark = performance.getEntriesByName("acpmux:handshakeStart")[0];
      if (!mark) return false;
      const script = performance.getEntriesByType("resource").find((entry) => entry.name.endsWith("/pane.js"));
      return { handshake: mark.startTime, paneLoaded: script ? script.responseEnd : -1 };
    },
    undefined,
    { polling: 5, timeout: 60_000 },
  );
  const marks = await handle.jsonValue();
  let result;
  if (withProfile) result = await profiled;
  await context.close();
  return { ...marks, profile: result };
}

function stats(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.round(q * (sorted.length - 1))))];
  const r = (v) => Math.round(v);
  return `median=${r(at(0.5))} p10=${r(at(0.1))} p90=${r(at(0.9))} min=${r(sorted[0])} max=${r(sorted.at(-1))}`;
}

/// Self time by source file over the profile's samples (a node's self time is its sample count).
function selfBySource(profile, sites, base) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const counts = new Map();
  for (const id of profile.samples) counts.set(id, (counts.get(id) ?? 0) + 1);
  const deltas = profile.timeDeltas;
  const sampleMs = deltas.length ? deltas.reduce((a, b) => a + b, 0) / deltas.length / 1000 : 0.1;
  const totals = new Map();
  for (const [id, count] of counts) {
    const frame = byId.get(id).callFrame;
    let name;
    if (frame.url.startsWith(base)) {
      const script = frame.url.slice(base.length + 1).replace(/\?.*$/, "");
      name = siteOf(sites, script, frame.lineNumber, frame.columnNumber);
    } else name = frame.url ? frame.url : `(${frame.functionName || "native"})`;
    totals.set(name, (totals.get(name) ?? 0) + count * sampleMs);
  }
  return [...totals.entries()].sort((a, b) => b[1] - a[1]);
}

/// Time by each task's entry (the outermost script frame of a sample's stack): the module's own
/// evaluation versus React's render and effect tasks, with when each first and last ran.
function byEntry(profile, sites, base) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const label = (frame) => {
    if (!frame.url.startsWith(base)) return `${frame.functionName || "(anonymous)"} ${frame.url || ""}`.trim();
    const script = frame.url.slice(base.length + 1).replace(/\?.*$/, "");
    return `${frame.functionName || "(top level)"} ${siteOf(sites, script, frame.lineNumber, frame.columnNumber)} ${script}:${frame.lineNumber}`;
  };
  const rows = new Map();
  let t = profile.startTime;
  profile.samples.forEach((id, index) => {
    t += profile.timeDeltas[index] ?? 0;
    let entry;
    for (let at = id; at !== undefined; at = parent.get(at)) {
      const frame = byId.get(at).callFrame;
      if (frame.url) entry = at;
    }
    if (entry === undefined) return;
    const key = label(byId.get(entry).callFrame);
    const row = rows.get(key) ?? { ms: 0, first: t, last: t };
    row.ms += (profile.timeDeltas[index + 1] ?? profile.timeDeltas[index] ?? 0) / 1000;
    row.last = t;
    rows.set(key, row);
  });
  return [...rows.entries()]
    .map(([key, row]) => [key, row.ms, (row.first - profile.startTime) / 1000, (row.last - profile.startTime) / 1000])
    .sort((a, b) => b[1] - a[1]);
}

/// Time in the modules' own evaluation (samples whose outermost script frame is a chunk's or
/// pane.js's top level, not React's scheduler or react-dom's tasks), by source of the sampled frame.
function moduleEvalBySource(profile, sites, base) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const where = (frame) => {
    const script = frame.url.slice(base.length + 1).replace(/\?.*$/, "");
    return siteOf(sites, script, frame.lineNumber, frame.columnNumber);
  };
  const totals = new Map();
  let all = 0;
  profile.samples.forEach((id, index) => {
    let entry;
    for (let at = id; at !== undefined; at = parent.get(at)) if (byId.get(at).callFrame.url) entry = at;
    if (entry === undefined) return;
    const top = byId.get(entry).callFrame;
    if (top.functionName || !top.url.startsWith(base) || where(top).includes("node_modules/react-dom")) return;
    const frame = byId.get(id).callFrame;
    const name = frame.url.startsWith(base) ? where(frame) : `(${frame.functionName || "native"})`;
    const ms = (profile.timeDeltas[index + 1] ?? profile.timeDeltas[index] ?? 0) / 1000;
    totals.set(name, (totals.get(name) ?? 0) + ms);
    all += ms;
  });
  return { all, totals };
}

const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)] : 0;
};

const chrome = findChrome();
const browser = await chromium.launch({ executablePath: chrome, args: ["--no-sandbox"] });
const servers = await Promise.all(dirs.map(serve));
const bases = servers.map((server) => `http://127.0.0.1:${server.address().port}`);
try {
  for (const rate of rates) {
    const times = dirs.map(() => []);
    const loads = dirs.map(() => []);
    // One warm-up per dir (the disk cache, Chrome's first compile of the harness).
    for (let d = 0; d < dirs.length; d += 1) await oneRun(browser, bases[d], rate, false);
    for (let run = 0; run < runs; run += 1)
      for (let d = 0; d < dirs.length; d += 1) {
        const marks = await oneRun(browser, bases[d], rate, false);
        times[d].push(marks.handshake);
        loads[d].push(marks.paneLoaded);
      }
    for (let d = 0; d < dirs.length; d += 1) {
      console.log(`PANE-HANDSHAKE dir=${dirs[d]} cpu=${rate}x runs=${runs} ${stats(times[d])}`);
      console.log(`PANE-JS-LOADED dir=${dirs[d]} cpu=${rate}x runs=${runs} ${stats(loads[d])}`);
    }
    if (profile) {
      const evals = dirs.map(() => []);
      const sources = dirs.map(() => new Map());
      for (let run = 0; run < profileRuns; run += 1)
        for (let d = 0; d < dirs.length; d += 1) {
          const marks = await oneRun(browser, bases[d], rate, true);
          const sites = await frameSites(dirs[d]);
          const { all, totals } = moduleEvalBySource(marks.profile, sites, bases[d]);
          evals[d].push(all);
          for (const [name, ms] of totals) sources[d].set(name, [...(sources[d].get(name) ?? []), ms]);
          if (run > 0) continue;
          if (saveProfile) fs.writeFileSync(`${saveProfile}-${d}-${rate}x.cpuprofile`, JSON.stringify(marks.profile));
          const rows = selfBySource(marks.profile, sites, bases[d]);
          const total = rows.reduce((sum, [, ms]) => sum + ms, 0);
          console.log(
            `PANE-PROFILE dir=${dirs[d]} cpu=${rate}x handshake=${Math.round(marks.handshake)}ms sampled=${Math.round(total)}ms (self time by source, top ${top})`,
          );
          for (const [name, ms] of rows.slice(0, top)) console.log(`  ${ms.toFixed(1).padStart(8)} ms  ${name}`);
          console.log(`PANE-ENTRIES dir=${dirs[d]} cpu=${rate}x (inclusive ms by task entry; first..last ms since profile start)`);
          for (const [name, ms, first, last] of byEntry(marks.profile, sites, bases[d]).slice(0, 12))
            console.log(`  ${ms.toFixed(1).padStart(8)} ms  ${first.toFixed(0).padStart(6)}..${last.toFixed(0).padEnd(6)} ${name}`);
        }
      for (let d = 0; d < dirs.length; d += 1) {
        console.log(`PANE-EVAL dir=${dirs[d]} cpu=${rate}x profiled=${profileRuns} module-eval ${stats(evals[d])}`);
        const rows = [...sources[d]]
          .map(([name, list]) => [name, median([...list, ...Array(profileRuns - list.length).fill(0)])])
          .sort((a, b) => b[1] - a[1]);
        for (const [name, ms] of rows.slice(0, top)) console.log(`  ${ms.toFixed(1).padStart(8)} ms  ${name}`);
      }
    }
  }
} finally {
  await browser.close();
  for (const server of servers) server.close();
}
