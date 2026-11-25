#!/usr/bin/env node
// What the agent pane's JS compile costs before first paint, and whether V8's code cache serves it: a built pane
// (scripts/cmux-next/build-agent-pane-web.sh --out DIR) loaded in a stock headless Chrome over http, A against B,
// alternating, with a DevTools trace of each load. No app, no Mac: it runs on any Linux host with Chrome.
//
//   node scripts/measure/pane-compile-ab.mjs DIR_A DIR_B [RUNS=10] [--warm]
//   node scripts/measure/pane-compile-ab.mjs --attach PORT [URL_SUBSTRING=cmux.agent]
//
// Cold (default): a fresh profile per load, so no code cache. --warm: one profile per side, cacheable responses
// and three priming loads first, so a working code cache is hit on every measured load.
// Per load: main-thread V8 compile ms (V8.CompileCode) and its count (lazy compiles), background parse ms
// (v8.parseOnBackground, the streaming thread), the end of the last module evaluation and first contentful paint,
// both from navigation start, and the code cache events (deserialized = consumed; produced = written again).
// Prints one JSON object: per side, the median of each and every run.
//
// --attach reads the same cache events from a running app instead: a cmux started with
// CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=PORT (scripts/cmux-next/trace.py does this). It reloads the
// first page whose URL has URL_SUBSTRING twice under a trace and says whether the second load consumed the cache.
//
// Found with it (2026-11-23, Chrome 158, docs/research/2026-11-23-startup-module-code-cache.md in cmuxterm-hq):
// an ES module's code cache is written on every load and never consumed, while the same code as a classic script
// is served from the cache.
import { spawn } from "node:child_process";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const argv = process.argv.slice(2);
const warm = argv.includes("--warm");
const attachAt = argv.indexOf("--attach");
const positional = argv.filter((a, i) => !a.startsWith("--") && (attachAt < 0 || i !== attachAt + 1));
const CHROME = process.env.CHROME || "/usr/bin/google-chrome";
const SETTLE_MS = Number(process.env.SETTLE_MS || 4000);
const types = { ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".html": "text/html", ".json": "application/json", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".woff2": "font/woff2" };
const CATEGORIES = ["devtools.timeline", "v8", "v8.execute", "disabled-by-default-v8.compile", "blink.user_timing", "loading"];
const CACHE_EVENTS = {
  consumed: ["V8.CompileDeserialize", "v8.deserializeOnBackground"],
  produced: ["v8.produceModuleCache", "v8.produceCache"],
};

function serve(dir) {
  return new Promise((resolve) => {
    const server = http
      .createServer((req, rsp) => {
        let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
        if (p === "/") p = "/index.html";
        const file = path.join(dir, p);
        fs.readFile(file, (err, body) => {
          if (err) {
            rsp.writeHead(404);
            return rsp.end();
          }
          rsp.writeHead(200, {
            "content-type": types[path.extname(file)] || "application/octet-stream",
            "cache-control": warm ? "max-age=31536000, immutable" : "no-store",
          });
          rsp.end(body);
        });
      })
      .listen(0, "127.0.0.1", () => resolve(server));
  });
}

/// A DevTools session: `send(method, params)` resolves with the reply; trace events collect into `events`.
async function session(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  let id = 0;
  const waiting = new Map();
  const events = [];
  let traceDone = () => {};
  ws.onmessage = (m) => {
    const msg = JSON.parse(String(m.data));
    if (msg.id && waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    } else if (msg.method === "Tracing.dataCollected") events.push(...msg.params.value);
    else if (msg.method === "Tracing.tracingComplete") traceDone();
  };
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      const i = ++id;
      waiting.set(i, resolve);
      ws.send(JSON.stringify({ id: i, method, params }));
    });
  const trace = async (during) => {
    events.length = 0;
    const complete = new Promise((r) => (traceDone = r));
    await send("Tracing.start", { traceConfig: { includedCategories: CATEGORIES }, transferMode: "ReportEvents" });
    await during();
    await send("Tracing.end");
    await complete;
    return [...events];
  };
  return { ws, send, trace };
}

async function pageTarget(port, match = () => true) {
  for (let i = 0; i < 100; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = list.find((t) => t.type === "page" && match(t));
      if (page) return page;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`no page target on port ${port}`);
}

function summarize(events) {
  const mains = new Set(events.filter((e) => e.name === "thread_name" && e.args?.name === "CrRendererMain").map((e) => `${e.pid}:${e.tid}`));
  const onMain = (e) => mains.has(`${e.pid}:${e.tid}`);
  const sum = (pred) => events.filter((e) => e.ph === "X" && pred(e)).reduce((a, e) => a + (e.dur || 0), 0) / 1000;
  const count = (names) => events.filter((e) => names.includes(e.name)).length;
  const nav = events.find((e) => e.name === "navigationStart" && e.args?.data?.documentLoaderURL?.startsWith("http"));
  const fcp = events.find((e) => e.name === "firstContentfulPaint");
  const evalEnds = events.filter((e) => onMain(e) && e.ph === "X" && e.name === "v8.evaluateModule").map((e) => e.ts + e.dur);
  const scriptEnds = events.filter((e) => onMain(e) && e.ph === "X" && e.name === "EvaluateScript").map((e) => e.ts + e.dur);
  const ends = evalEnds.length ? evalEnds : scriptEnds;
  return {
    mainCompileMs: sum((e) => onMain(e) && e.name === "V8.CompileCode"),
    mainCompiles: events.filter((e) => onMain(e) && e.name === "V8.CompileCode").length,
    backgroundParseMs: sum((e) => !onMain(e) && e.name === "v8.parseOnBackground"),
    scriptsDoneMs: nav && ends.length ? (Math.max(...ends) - nav.ts) / 1000 : null,
    fcpMs: nav && fcp ? (fcp.ts - nav.ts) / 1000 : null,
    cacheConsumed: count(CACHE_EVENTS.consumed),
    cacheProduced: count(CACHE_EVENTS.produced),
  };
}

const servers = new Map();
async function loadOnce(dir) {
  if (!servers.has(dir) || !warm) servers.set(dir, await serve(dir));
  const server = servers.get(dir);
  const profile = warm
    ? path.join(os.tmpdir(), `pane-compile-ab-${process.pid}-${path.basename(dir)}`)
    : fs.mkdtempSync(path.join(os.tmpdir(), "pane-compile-ab-"));
  fs.mkdirSync(profile, { recursive: true });
  const port = 9300 + Math.floor(Math.random() * 600);
  const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-background-networking", "about:blank"], { stdio: "ignore" });
  try {
    const s = await session((await pageTarget(port)).webSocketDebuggerUrl);
    await s.send("Page.enable");
    const events = await s.trace(async () => {
      await s.send("Page.navigate", { url: `http://127.0.0.1:${server.address().port}/index.html` });
      await new Promise((r) => setTimeout(r, SETTLE_MS));
    });
    if (warm) {
      s.send("Browser.close");
      await new Promise((r) => chrome.once("exit", r));
    }
    s.ws.close();
    return summarize(events);
  } finally {
    chrome.kill("SIGKILL");
    if (!warm) {
      server.close();
      fs.rmSync(profile, { recursive: true, force: true });
    }
  }
}

const median = (xs) => {
  const s = xs.filter((x) => x != null).sort((a, b) => a - b);
  return s.length ? s[Math.floor((s.length - 1) / 2)] : null;
};

if (attachAt >= 0) {
  const port = argv[attachAt + 1];
  const want = positional[0] || "cmux.agent";
  const target = await pageTarget(port, (t) => t.url.includes(want));
  const s = await session(target.webSocketDebuggerUrl);
  await s.send("Page.enable");
  const loads = [];
  for (let i = 0; i < 2; i++) {
    loads.push(
      summarize(
        await s.trace(async () => {
          await s.send("Page.reload", { ignoreCache: false });
          await new Promise((r) => setTimeout(r, SETTLE_MS));
        }),
      ),
    );
  }
  s.ws.close();
  console.log(JSON.stringify({ url: target.url, loads, secondLoadConsumedCache: loads[1].cacheConsumed > 0 }, null, 1));
  process.exit(0);
}

const [dirA, dirB, runsArg] = positional;
if (!dirA || !dirB) {
  console.error("usage: pane-compile-ab.mjs DIR_A DIR_B [RUNS=10] [--warm] | --attach PORT [URL_SUBSTRING]");
  process.exit(2);
}
const runs = Number(runsArg || 10);
const sides = { A: { dir: dirA, runs: [] }, B: { dir: dirB, runs: [] } };
if (warm) for (const side of Object.values(sides)) for (let i = 0; i < 3; i++) await loadOnce(side.dir);
for (let i = 0; i < runs; i++) {
  for (const key of i % 2 ? ["B", "A"] : ["A", "B"]) {
    const result = await loadOnce(sides[key].dir);
    sides[key].runs.push(result);
    console.error(key, i, JSON.stringify(result));
  }
}
for (const server of servers.values()) server.close();
if (warm) for (const side of Object.values(sides)) fs.rmSync(path.join(os.tmpdir(), `pane-compile-ab-${process.pid}-${path.basename(side.dir)}`), { recursive: true, force: true });
const out = { warm, runs, chrome: CHROME };
for (const [key, side] of Object.entries(sides)) {
  const fields = Object.keys(side.runs[0]);
  out[key] = { dir: side.dir, median: Object.fromEntries(fields.map((f) => [f, median(side.runs.map((r) => r[f]))])), runs: side.runs };
}
console.log(JSON.stringify(out, null, 1));
