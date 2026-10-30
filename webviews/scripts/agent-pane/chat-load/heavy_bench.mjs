// Heavy chat load (Leo, 2026-10-29: "shit renders like a powerpoint"): the shipped agent pane on
// its in-page mock daemon, loaded as his main chat is: a transcript of thousands of heavy turns,
// working sub-sessions under it, other agents' messages queued behind its running turn (and more
// arriving), and a turn streaming at full speed. Through the pane's own load hooks (loadDebug.ts),
// in headless Chromium it reports:
//   open        loadSeed: time to first content and to a settled transcript;
//   stream      loadRun: frame intervals and per-frame work (p50/p95/p99/max), dropped frames, long
//               tasks (count, per 10 s, total, max), with peer messages and sub-session updates arriving;
//   subsession  loadOpenSubsession: select one sub-session (the host's answer to a tray or card
//               click) to the first frame that shows its newest message, idle and while streaming;
//   profile     (--profile) the top functions by self time while the turn streams (CDP sampling).
//
//   node heavy_bench.mjs --pane DIR [--out OUT_JSON] [--turns 4000] [--subsessions 50] [--child-turns 20]
//        [--peers 285] [--peer-every-ms 250] [--child-touch-ms 200] [--seconds 10] [--scroll-speed 0]
//        [--repeat 3] [--profile] [--port 4320]
// DIR is scripts/cmux-next/build-agent-pane-web.sh --out DIR; heavy_run.sh builds it and runs this.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import pw from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const has = (name) => process.argv.includes(`--${name}`);
const num = (name, fallback) => Number(arg(name, String(fallback)));
const paneDir = path.resolve(arg("pane"));
const out = arg("out", "heavy.json");
const port = num("port", 4320);
const turns = num("turns", 4000);
const subsessions = num("subsessions", 50);
const childTurns = num("child-turns", 20);
const repeat = num("repeat", 3);
const run = {
  seconds: num("seconds", 10),
  scroll_speed: num("scroll-speed", 0),
  peer_messages: num("peers", 285),
  peer_every_ms: num("peer-every-ms", 250),
  child_touch_ms: num("child-touch-ms", 200),
};

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const file = path.join(paneDir, decodeURIComponent(url.pathname === "/" ? "/index.html" : url.pathname));
  if (!file.startsWith(paneDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${port}`;

// The native host's replies, on the mock transport (as browser_bench.mjs's shim with `mock`).
function shim() {
  const reply = (request) => {
    const method = String(request.method).replace(/^cmux\.agent\./, "");
    switch (method) {
      case "handshake":
      case "ready":
        return { ok: true, value: { protocolVersion: 1, transport: "mock" } };
      case "acp.trust.get":
        return { ok: true, value: { cwd: request.params?.cwd ?? "/tmp", level: "trusted" } };
      case "pane.context":
        return { ok: true, value: { cwd: "/tmp", urls: [] } };
      default:
        return { ok: true, value: null };
    }
  };
  window.webkit = { messageHandlers: { agentSession: { postMessage: (request) => Promise.resolve(reply(request)) } } };
  // The mock daemon logs each request it answers here (mock.ts `answer`): the requests per method.
  window.cmuxGalleryLog = [];
}

const browser = await pw.chromium.launch();

/// A page on the mock daemon with the load session open; returns it once its transcript settled.
async function openLoaded() {
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 1100, height: 900 } });
  const page = await context.newPage();
  await page.addInitScript(shim);
  await page.goto(`${origin}/index.html`);
  await page.waitForFunction(() => !!window.cmuxAcpmuxDebug, null, { timeout: 60_000 });
  await page.waitForTimeout(1000);
  const seed = await page.evaluate(
    ([count, options]) => window.cmuxAcpmuxDebug.loadSeed(count, options),
    [turns, { subsessions, child_turns: childTurns }],
  );
  return { context, page, seed };
}

const median = (values) => {
  const v = values.filter((x) => typeof x === "number").sort((a, b) => a - b);
  return v.length ? v[Math.floor((v.length - 1) / 2)] : null;
};
const pick = (row, keys) => Object.fromEntries(keys.map((k) => [k, k.split(".").reduce((o, p) => o?.[p], row)]));
const STREAM_KEYS = [
  "display.p50_ms", "display.p95_ms", "display.p99_ms", "display.max_ms", "display.dropped_frames", "display.frames",
  "work_ms.p50", "work_ms.p95", "work_ms.p99", "work_ms.max", "over_60hz_budget", "over_120hz_budget",
  "long_tasks.count", "long_tasks.per_10s", "long_tasks.total_ms", "long_tasks.max_ms", "rows", "deltas", "peers",
  "child_updates", "layout_ms", "react_ms", "other_ms",
];
const SEED_KEYS = ["rows", "seed_ms", "first_content_ms", "open_ms"];
const OPEN_KEYS = ["first_content_ms", "settled_ms", "long_tasks.count", "long_tasks.max_ms", "rows"];
const medians = (rows, keys) =>
  Object.fromEntries(keys.map((k) => [k, median(rows.map((row) => pick(row, [k])[k]))]));

const results = { harness: "heavy_bench.mjs", load: { turns, subsessions, childTurns, ...run }, runs: [] };
for (let i = 0; i < repeat; i += 1) {
  const { context, page, seed } = await openLoaded();
  const stream = await page.evaluate(async (options) => {
    const from = window.cmuxGalleryLog.length;
    const result = await window.cmuxAcpmuxDebug.loadRun(options);
    const methods = {};
    for (const entry of window.cmuxGalleryLog.slice(from)) methods[entry.method] = (methods[entry.method] ?? 0) + 1;
    return { ...result, requests: methods };
  }, run);
  // A fresh page for each open: the stream above left the parent's queue and rows grown.
  await context.close();
  const idle = await openLoaded();
  const openIdle = await idle.page.evaluate(
    (options) => window.cmuxAcpmuxDebug.loadOpenSubsession(options),
    { index: 7, child_turns: childTurns },
  );
  await idle.context.close();
  const busy = await openLoaded();
  const openBusy = await busy.page.evaluate(
    (options) => window.cmuxAcpmuxDebug.loadOpenSubsession(options),
    { index: 11, child_turns: childTurns, streaming: { ...run, seconds: 6 } },
  );
  const dom = await busy.page.evaluate(() => document.getElementsByTagName("*").length);
  await busy.context.close();
  const entry = { seed, stream, open_idle: openIdle, open_streaming: openBusy, dom_nodes_after: dom };
  results.runs.push(entry);
  console.log(
    JSON.stringify({
      run: i,
      seed: pick(seed, SEED_KEYS),
      stream: pick(stream, STREAM_KEYS),
      open_idle: pick(openIdle, OPEN_KEYS),
      open_streaming: pick(openBusy, OPEN_KEYS),
    }),
  );
}
results.median = {
  seed: medians(results.runs.map((r) => r.seed), SEED_KEYS),
  stream: medians(results.runs.map((r) => r.stream), STREAM_KEYS),
  open_idle: medians(results.runs.map((r) => r.open_idle), OPEN_KEYS),
  open_streaming: medians(results.runs.map((r) => r.open_streaming), OPEN_KEYS),
};
console.log(JSON.stringify({ median: results.median }, null, 1));
console.log(JSON.stringify({ longest_frames: results.runs.at(-1).stream.longest?.slice(0, 6) }));
console.log(JSON.stringify({ requests_during_stream: results.runs.at(-1).stream.requests, seconds: run.seconds }));

if (has("profile")) {
  const { context, page } = await openLoaded();
  const cdp = await context.newCDPSession(page);
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
  await cdp.send("Profiler.start");
  await page.evaluate((options) => window.cmuxAcpmuxDebug.loadRun(options), run);
  const { profile } = await cdp.send("Profiler.stop");
  const self = new Map();
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  profile.samples.forEach((id, i) => {
    const f = byId.get(id).callFrame;
    const key = `${f.functionName || "(anon)"} ${f.url.split("/").pop()}:${f.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000);
  });
  // Who calls a native frame (no URL): its JS caller's self time, for the hottest ones.
  const parents = new Map();
  for (const node of profile.nodes) for (const child of node.children ?? []) parents.set(child, node.id);
  const keyOf = (f) => `${f.functionName || "(anon)"} ${f.url.split("/").pop()}:${f.lineNumber + 1}`;
  const callers = new Map();
  profile.samples.forEach((id, i) => {
    const f = byId.get(id).callFrame;
    if (f.url || ["(idle)", "(program)", "(garbage collector)", "(root)"].includes(f.functionName)) return;
    let parent = parents.get(id);
    const chain = [];
    while (parent !== undefined && chain.length < 4) {
      const pf = byId.get(parent).callFrame;
      if (pf.url) chain.push(keyOf(pf));
      parent = parents.get(parent);
    }
    const key = `${keyOf(f)} <- ${chain.join(" <- ")}`;
    callers.set(key, (callers.get(key) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000);
  });
  const total = [...self.values()].reduce((a, b) => a + b, 0);
  const top = [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40);
  // The bundle's source line of each hot frame in it (heavy_run.sh builds it unminified).
  const lines = new Map();
  const source = (key) => {
    const match = /^(.*) ([\w.-]+\.js):(\d+)$/.exec(key);
    if (!match) return "";
    const file = path.join(paneDir, match[2]);
    if (!lines.has(file)) lines.set(file, fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n") : []);
    const at = Number(match[3]) - 1;
    const near = lines.get(file).slice(Math.max(0, at - 40), at + 1).reverse();
    const marker = near.find((line) => /^\/\/ src\//.test(line.trim()));
    return `${(lines.get(file)[at] ?? "").trim().slice(0, 100)}${marker ? `   [${marker.trim()}]` : ""}`;
  };
  // The hottest bundle lines by sample (each node's positionTicks), with their code: what a hot
  // function spends its own time on.
  const lineTicks = new Map();
  for (const node of profile.nodes) {
    const file = node.callFrame.url.split("/").pop();
    if (!file) continue;
    for (const tick of node.positionTicks ?? []) {
      const key = `${file}:${tick.line}`;
      lineTicks.set(key, (lineTicks.get(key) ?? 0) + tick.ticks);
    }
  }
  const interval = profile.samples.length ? total / profile.samples.length : 0;
  console.log("== hottest bundle lines (self samples)");
  results.hot_lines = [];
  for (const [key, ticks] of [...lineTicks.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)) {
    const [file, line] = key.split(":");
    const code = source(`x ${file}:${line}`);
    results.hot_lines.push([key, Math.round(ticks * interval), code]);
    console.log(`${(ticks * interval).toFixed(1).padStart(9)} ms  ${key}  ${code}`);
    // The function the line is in: the nearest line above it that declares one.
    const text = lines.get(path.join(paneDir, file)) ?? [];
    for (let at = Number(line) - 1; at >= Math.max(0, Number(line) - 400); at -= 1) {
      if (/^\s*(?:async )?function \w+|^\s*const \w+ = (?:\(0, import_react\d*\.use\w+\)|use\w+)|^\s*\(0, import_react\d*\.useLayoutEffect\)|^\s*function \w+/.test(text[at] ?? "")) {
        console.log(`             in ${file}:${at + 1}  ${(text[at] ?? "").trim().slice(0, 100)}`);
        break;
      }
    }
  }
  console.log("== native frames by JS caller");
  for (const [key, value] of [...callers.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12))
    console.log(`${value.toFixed(1).padStart(9)} ms  ${key}`);
  results.callers = [...callers.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20);
  results.profile = { sampled_ms: Math.round(total), top: top.map(([k, v]) => [k, Math.round(v * 10) / 10]) };
  console.log(`== profile stream: ${Math.round(total)} ms sampled`);
  for (const [key, value] of top) console.log(`${value.toFixed(1).padStart(9)} ms  ${key}  ${source(key)}`);
  await context.close();
}

fs.writeFileSync(out, JSON.stringify(results, null, 1));
await browser.close();
server.close();
