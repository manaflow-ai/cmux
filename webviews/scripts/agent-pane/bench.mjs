// l10n-allow-file: bench output, not shipped UI.
// The agent pane's main-thread cost with a long session list and a busy daemon (Leo's nightly at
// ~12,000 listed chats burned 1.2 cores while idle). Serves the real pane source (Vite dev server,
// so the profile names source files) against the in-page mock daemon (mock.ts) listing N chats in
// keyset pages of 200, then for each run drives the daemon the way a busy acpmux does:
//   - `_acpmux/session_changed` status flips on ~200 chats, `--rate` per second;
//   - (run mode `busy` or `dropped`; `idle` sends nothing)
//   - `_acpmux/lagged {watch:true, reason:"list_changed"}` every `--lag-every` seconds
//     (`--lag-dropped` adds `dropped:1`, the shape that makes the pane reread the list).
// After a warm-up it reads CDP Performance.getMetrics (TaskDuration, ScriptDuration) over
// `--seconds` and takes a CDP Profiler CPU profile; it prints CPU ms per second and the top
// functions by self and total time, and writes each .cpuprofile to $FAST_CHECKS_OUT (or --out).
//
//   node scripts/agent-pane/session-list-cpu-bench.mjs [--runs 1000:busy,12000:busy,12000:idle]
//     [--seconds 60] [--warmup 10] [--rate 5] [--lag-every 20] [--lag-dropped] [--peers 30]
//
// From webviews/. Run it at two commits for a before/after on the same harness.
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { diff, takeSnapshot } from "./heap-diff.mjs";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const flag = (name) => process.argv.includes(`--${name}`);
const runs = arg("runs", "1000:busy,12000:busy,12000:idle")
  .split(",")
  .map((spec) => {
    const [n, mode] = spec.split(":");
    return { sessions: Number(n), mode: mode ?? "busy" };
  });
const SECONDS = Number(arg("seconds", "60"));
const WARMUP = Number(arg("warmup", "10"));
const RATE = Number(arg("rate", "5"));
const LAG_EVERY = Number(arg("lag-every", "20"));
const LAG_DROPPED = flag("lag-dropped");
const PEERS = Number(arg("peers", "30"));
const PAD = Number(arg("pad", "2400"));
const PORT = Number(arg("port", "4199"));
// `--hidden N`: N more pages of the pane in the same browser, hidden (document.visibilityState),
// as the app keeps hidden chat tabs awake in the same renderer; their CPU counts in the run's total.
const HIDDEN = Number(arg("hidden", "0"));
// `--prod`: a production build of the pane (vite build, served statically) instead of the dev
// server, so React's development checks are not in the numbers.
const PROD = flag("prod");
// `--snapshots`: a heap snapshot after the warm-up and one after the run (each after a GC); the
// result lists what the run added and kept, by constructor and by the object holding it.
const SNAPSHOTS = flag("snapshots");
// `--sample S`: every S seconds of the run, a GC and the heap, DOM node and listener counts, so
// growth over time shows as a series (a leak climbs; churn comes back down).
const SAMPLE = Number(arg("sample", "0"));
// `--replay FILE` (run mode `replay`): records of a real chat's log with its text replaced by filler
// (structure, sizes and timing only), emitted into the shown chat at their recorded spacing / --speed.
const REPLAY = arg("replay", "");
const SPEED = Number(arg("speed", "1"));
const OUT = arg("out", process.env.FAST_CHECKS_OUT ?? fs.mkdtempSync("/tmp/session-list-cpu-"));
fs.mkdirSync(OUT, { recursive: true });

let server;
if (PROD) {
  // The repo's Vite (vite-plus, `vp`), as package.json's scripts call it.
  const outDir = fs.mkdtempSync("/tmp/session-list-cpu-build-");
  const built = spawn(
    "node_modules/.bin/vp",
    ["build", "--config", "vite.config.acpmux-pane.mjs", "--outDir", outDir, "--emptyOutDir", "--sourcemap"],
    {
      stdio: "inherit",
    },
  );
  const code = await new Promise((resolve) => built.on("exit", resolve));
  if (code !== 0) throw new Error(`pane build failed (${code})`);
  // A static server for the build (no dev transforms, production React).
  const http = await import("node:http");
  const types = {
    ".html": "text/html",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".css": "text/css",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".wasm": "application/wasm",
    ".woff2": "font/woff2",
    ".map": "application/json",
  };
  const staticServer = http.createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    let file = path.join(outDir, decodeURIComponent(url.pathname));
    if (!file.startsWith(outDir)) return res.writeHead(403).end();
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
    if (!fs.existsSync(file)) return res.writeHead(404).end();
    res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve) => staticServer.listen(PORT, "127.0.0.1", resolve));
  server = { pid: undefined, stdout: { on() {} }, stderr: { on() {} }, close: () => staticServer.close() };
} else
  server = spawn("bun", ["run", "dev:agent-pane", "--", "--host", "127.0.0.1", "--strictPort"], {
    env: { ...process.env, CMUX_AGENT_PANE_DEV_PORT: String(PORT) },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
let serverLog = "";
server.stdout.on("data", (chunk) => (serverLog += chunk));
server.stderr.on("data", (chunk) => (serverLog += chunk));
const stopServer = () => {
  if (server.close) return server.close();
  try {
    process.kill(-server.pid, "SIGTERM");
  } catch {
    // already gone
  }
};
process.on("exit", stopServer);

const base = `http://127.0.0.1:${PORT}/`;
for (let tries = 0; ; tries += 1) {
  try {
    if ((await fetch(base)).ok) break;
  } catch {
    // not up yet
  }
  if (tries > 240) throw new Error(`dev server never answered\n${serverLog}`);
  await new Promise((resolve) => setTimeout(resolve, 500));
}

/** Per function (name, url, line): self ms and total ms (a function counted once per sample). */
function summarize(profile) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const key = (node) => {
    const frame = node.callFrame;
    const url = frame.url.replace(/^https?:\/\/[^/]+\//, "").replace(/\?.*$/, "");
    return `${frame.functionName || "(anonymous)"} ${url}:${frame.lineNumber + 1}`;
  };
  const self = new Map();
  const total = new Map();
  let all = 0;
  let idle = 0;
  profile.samples.forEach((id, index) => {
    const ms = (profile.timeDeltas[index + 1] ?? profile.timeDeltas[index] ?? 0) / 1000;
    const node = byId.get(id);
    const name = node.callFrame.functionName;
    all += ms;
    if (name === "(idle)" || name === "(program)" || name === "(garbage collector)") {
      if (name === "(idle)") idle += ms;
      self.set(name, (self.get(name) ?? 0) + ms);
      return;
    }
    self.set(key(node), (self.get(key(node)) ?? 0) + ms);
    const seen = new Set();
    for (let at = id; at !== undefined; at = parent.get(at)) {
      const k = key(byId.get(at));
      if (seen.has(k)) continue;
      seen.add(k);
      total.set(k, (total.get(k) ?? 0) + ms);
    }
  });
  const top = (map, n) =>
    [...map.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, n)
      .map(([name, ms]) => ({ ms: Math.round(ms), name }));
  return { wallMs: Math.round(all), busyMs: Math.round(all - idle), self: top(self, 30), total: top(total, 45) };
}

const browser = await chromium.launch();
const results = [];
for (const run of runs) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const hiddenPages = [];
  for (let index = 0; index < HIDDEN; index += 1) {
    const hidden = await context.newPage();
    await hidden.addInitScript(
      ({ sessions, peers, pad }) => {
        globalThis.cmuxAcpmuxMockListSize = sessions;
        globalThis.cmuxAcpmuxMockListPeers = peers;
        globalThis.cmuxAcpmuxMockListPad = pad;
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
        Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      },
      { sessions: run.sessions, peers: PEERS, pad: PAD },
    );
    await hidden.goto(`${base}?mock`);
    hiddenPages.push(hidden);
  }
  const page = await context.newPage();
  page.on("pageerror", (error) => console.error("pageerror", String(error).slice(0, 300)));
  await page.addInitScript(
    ({ sessions, peers, pad }) => {
      globalThis.cmuxAcpmuxMockListSize = sessions;
      globalThis.cmuxAcpmuxMockListPeers = peers;
      globalThis.cmuxAcpmuxMockListPad = pad;
    },
    { sessions: run.sessions, peers: PEERS, pad: PAD },
  );
  const t0 = Date.now();
  await page.goto(`${base}?mock`);
  await page.waitForFunction(
    () => globalThis.cmuxAcpmuxMockLive && globalThis.cmuxAcpmuxDebug?.chatState?.().sessionId,
    null,
    {
      timeout: 180_000,
    },
  );
  // Count every request the page sends the daemon, by method.
  const firstPageBytes = await page.evaluate(() => {
    const live = globalThis.cmuxAcpmuxMockLive;
    const counts = (globalThis.__benchRequests = {});
    const send = live.send.bind(live);
    live.send = (raw) => {
      try {
        const method = JSON.parse(raw).method;
        counts[method] = (counts[method] ?? 0) + 1;
      } catch {
        // not JSON
      }
      send(raw);
    };
    return JSON.stringify({ sessions: live.sessions.slice(0, 200) }).length;
  });
  const openMs = Date.now() - t0;
  // Let the rest of the list page in.
  await page.waitForTimeout(8_000);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
  await page.evaluate(
    ({ mode, rate, lagEvery, lagDropped: dropped }) => {
      let lagDropped = dropped;
      if (mode === "idle") return;
      if (mode.startsWith("real")) {
        // `real` runs all three sources; `real.stream`, `real.self`, `real.flips` (joined by "."),
        // only those named, to attribute the cost.
        const parts = mode === "real" ? ["stream", "self", "flips"] : mode.split(".").slice(1);
        // The shape of 60 s recorded on Leo's Mac (structure and rates only, synthetic content):
        // the shown chat streams ~5.6 records/s (tool calls and their updates, subagent progress,
        // message chunks, background tasks) and its own session_changed comes every ~1.6 s at ~100 KB
        // (a 512-span timeBreakdown and 187 tools); other chats flip status ~4.4/s at ~3 KB.
        const live = globalThis.cmuxAcpmuxMockLive;
        const shown = globalThis.cmuxAcpmuxDebug.chatState().sessionId;
        const now = Date.now();
        const uuid = (i) => `0000${i}`.slice(-4).padStart(36, "0a1b2c3d-");
        const span = (i) => ({
          category: ["model", "tools", "waits", "think", "users", "other"][i % 6],
          startAt: now - (600 - i) * 5_000,
          endAt: now - (600 - i) * 5_000 + 4_000,
          turnId: uuid(Math.floor(i / 8)),
          turnSeq: i,
          turnTokens: 1_000 + i,
        });
        let spanAt = 512;
        const spans = Array.from({ length: 512 }, (_, i) => span(i));
        const tools = Array.from({ length: 187 }, (_, i) => ({
          canToggle: true,
          enabled: i % 7 !== 0,
          id: `tool-${i}`.padEnd(12, "x"),
          kind: "tool",
          name: `Tool${i}`.padEnd(8, "x"),
          source: "mcp_",
        }));
        live.emit(shown, { mux: "turn_started" });
        let tick = 0;
        let toolId = 0;
        const text = "Checking the session list again and reading the next file in the tree. ";
        const kinds = [
          "tool_call",
          "tool_call_update",
          "subagent_progress",
          "tool_call",
          "tool_call_update",
          "agent_message_chunk",
          "subagent_progress",
          "tool_call",
          "tool_call_update",
          "background_task_update",
        ];
        let flips = 0;
        globalThis.__benchDriver = [
          parts.includes("stream") &&
            setInterval(() => {
              if (parts.includes("turns") && tick > 0 && tick % 60 === 0) {
                live.emit(shown, { mux: "turn_result", msg: { status: "completed" } });
                live.emit(shown, { mux: "user_message", msg: { text: `Next step ${tick / 60}` } });
                live.emit(shown, { mux: "turn_started" });
              }
              const kind = kinds[tick++ % kinds.length];
              if (kind === "tool_call") {
                toolId += 1;
                live.emit(shown, {
                  update: {
                    sessionUpdate: "tool_call",
                    toolCallId: `toolu_${toolId}`,
                    title: `Read file ${toolId}`,
                    kind: "read",
                    status: "in_progress",
                    rawInput: { file_path: `/work/src/file-${toolId}.ts`, note: text.repeat(8) },
                  },
                  meta: { claudeCode: { toolName: "Read" } },
                });
              } else if (kind === "tool_call_update")
                live.emit(shown, {
                  update: {
                    sessionUpdate: "tool_call_update",
                    toolCallId: `toolu_${toolId}`,
                    status: "completed",
                    content: [{ type: "content", content: { type: "text", text: text.repeat(5) } }],
                  },
                });
              else if (kind === "subagent_progress")
                live.emit(shown, {
                  update: {
                    sessionUpdate: "subagent_progress",
                    subagentSessionId: uuid(tick % 3),
                    action: "Reading files",
                    elapsedMs: tick * 180,
                    tokens: tick * 40,
                    toolUses: tick,
                  },
                });
              else if (kind === "agent_message_chunk")
                live.emit(shown, {
                  update: {
                    sessionUpdate: "agent_message_chunk",
                    messageId: `msg-${Math.floor(tick / 40)}`,
                    content: { type: "text", text: text },
                  },
                });
              else
                live.emit(shown, {
                  update: {
                    sessionUpdate: "background_task_update",
                    taskId: `task-${tick % 4}`,
                    toolCallId: `toolu_${toolId}`,
                    command: "sleep 30",
                    origin: "tool",
                    state: "running",
                  },
                });
            }, 1000 / 5.6),
          parts.includes("self") &&
            setInterval(() => {
              tick += parts.includes("stream") ? 0 : 9;
              spans.shift();
              spans.push(span(spanAt++));
              live.changeSession(shown, {
                status: "running",
                indicator: "working",
                lastSeq: tick,
                timeBreakdown: {
                  categories: ["model", "tools", "waits", "think", "users", "other"].map((id, i) => ({
                    id,
                    wallMs: 1_000 * (i + tick),
                  })),
                  spans: spans.map((s) => ({ ...s })),
                  tokensComplete: true,
                  totalMs: tick * 1_000,
                  totalTokens: tick * 900,
                },
                tools: tools.map((x) => ({ ...x })),
              });
            }, 1_620),
          parts.includes("flips") &&
            setInterval(() => {
              const index = Math.floor(Math.random() * 200);
              const running = (flips += 1) % 2 === 1;
              live.changeSession(`listed-${index}`, {
                status: running ? "running" : "idle",
                indicator: running ? "working" : "done",
              });
            }, 1000 / 4.4),
        ].filter(Boolean);
        return;
      }
      // `dropped`: the lag a full outbound queue sends (dropped > 0), which rereads the whole list.
      if (mode === "dropped") lagDropped = true;
      const live = globalThis.cmuxAcpmuxMockLive;
      let flips = 0;
      globalThis.__benchDriver = [
        setInterval(() => {
          // A status flip on one of ~200 listed chats (most from one peer, as Leo's fleet sends them).
          const index = Math.floor(Math.random() * 200);
          const running = (flips += 1) % 2 === 1;
          live.changeSession(`listed-${index}`, {
            status: running ? "running" : "idle",
            indicator: running ? "working" : "done",
          });
        }, 1000 / rate),
        setInterval(
          () =>
            live.deliver({
              jsonrpc: "2.0",
              method: "_acpmux/lagged",
              params: { watch: true, reason: "list_changed", ...(lagDropped ? { dropped: 1 } : {}) },
            }),
          lagEvery * 1000,
        ),
      ];
    },
    { mode: run.mode, rate: RATE, lagEvery: LAG_EVERY, lagDropped: LAG_DROPPED },
  );
  if (run.mode === "replay") {
    const records = JSON.parse(fs.readFileSync(REPLAY, "utf8"));
    const started = Date.now();
    let next = 0;
    (async () => {
      while (next < records.length && !page.isClosed()) {
        const due = (Date.now() - started) * SPEED;
        const batch = [];
        while (next < records.length && records[next].dt <= due) batch.push(records[next++]);
        if (batch.length)
          await page
            .evaluate((text) => {
              const live = globalThis.cmuxAcpmuxMockLive;
              const shown = globalThis.cmuxAcpmuxDebug.chatState().sessionId;
              for (const r of JSON.parse(text.replaceAll("SHOWN", shown))) {
                live.seq += 1;
                live.deliver({
                  jsonrpc: "2.0",
                  method: "_acpmux/event",
                  params: { sessionId: shown, seq: live.seq, at: Date.now(), dir: r.dir, kind: r.kind, msg: r.msg },
                });
              }
            }, JSON.stringify(batch))
            .catch(() => undefined);
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
      globalThis.__replayDone = next;
    })();
  }
  await page.waitForTimeout(WARMUP * 1000);
  const metrics = async () =>
    Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map((m) => [m.name, m.value]));
  await page.evaluate(() => {
    for (const key of Object.keys(globalThis.__benchRequests)) delete globalThis.__benchRequests[key];
  });
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 500 });
  const hiddenCdp = [];
  for (const hidden of hiddenPages) {
    const session = await context.newCDPSession(hidden);
    await session.send("Performance.enable", { timeDomain: "threadTicks" });
    hiddenCdp.push(session);
  }
  const hiddenTask = async () => {
    let sum = 0;
    for (const session of hiddenCdp)
      sum += (await session.send("Performance.getMetrics")).metrics.find((m) => m.name === "TaskDuration").value;
    return sum;
  };
  const hiddenBefore = await hiddenTask();
  await cdp.send("HeapProfiler.enable");
  await cdp.send("HeapProfiler.collectGarbage");
  const snapBefore = SNAPSHOTS ? await takeSnapshot(cdp) : null;
  const heapBefore = (await metrics()).JSHeapUsedSize;
  const before = await metrics();
  // Frame times (rAF deltas) and main-thread tasks over 16 ms (long-animation-frame, longtask).
  await page.evaluate(() => {
    const frames = [];
    const longTasks = [];
    let last = performance.now();
    let on = true;
    const tick = (now) => {
      frames.push(now - last);
      last = now;
      if (on) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    const observers = [];
    for (const type of ["long-animation-frame", "longtask"])
      try {
        const o = new PerformanceObserver((list) => {
          for (const e of list.getEntries())
            longTasks.push({
              type,
              ms: Math.round(e.duration),
              blockingMs: Math.round(e.blockingDuration ?? 0),
              scripts: (e.scripts ?? [])
                .sort((a, b) => b.duration - a.duration)
                .slice(0, 3)
                .map(
                  (s) =>
                    `${Math.round(s.duration)}ms ${s.invoker ?? ""} ${s.sourceFunctionName ?? ""} ${(s.sourceURL ?? "").replace(/^https?:\/\/[^/]+\//, "")}:${s.sourceCharPosition ?? ""}`,
                ),
            });
        });
        o.observe({ type, buffered: false });
        observers.push(o);
      } catch {}
    globalThis.__benchFrames = {
      frames,
      longTasks,
      stop: () => {
        on = false;
        for (const o of observers) o.disconnect();
      },
    };
  });
  await cdp.send("Profiler.start");
  const wallStart = Date.now();
  const series = [];
  if (SAMPLE > 0)
    for (let t = SAMPLE; t <= SECONDS; t += SAMPLE) {
      await page.waitForTimeout(SAMPLE * 1000);
      await cdp.send("HeapProfiler.collectGarbage");
      const m = await metrics();
      series.push({
        t,
        heapMB: Math.round(m.JSHeapUsedSize / 1e5) / 10,
        nodes: m.Nodes,
        listeners: m.JSEventListeners,
      });
    }
  else await page.waitForTimeout(SECONDS * 1000);
  const { profile } = await cdp.send("Profiler.stop");
  await cdp.send("HeapProfiler.collectGarbage");
  const after = await metrics();
  // Where the page's elements are: count by each element's own class and by its nearest classed
  // container below the root, the top 15 of each, to name what a growing node count belongs to.
  const census = await page.evaluate(() => {
    const own = new Map();
    const box = new Map();
    const detached = {
      li: document.querySelectorAll("li").length,
      rows: document.querySelectorAll("[data-index], [data-row-key], [data-key]").length,
    };
    for (const el of document.querySelectorAll("*")) {
      const c =
        typeof el.className === "string" && el.className ? el.className.split(" ")[0] : el.tagName.toLowerCase();
      own.set(c, (own.get(c) ?? 0) + 1);
      let up = el.parentElement;
      let depth = 0;
      while (up && depth < 40) {
        const k = typeof up.className === "string" ? up.className.split(" ")[0] : "";
        if (/(transcript|list|rows|worked|activity|group|tools|thread|virtual|scroller)/i.test(k)) break;
        up = up.parentElement;
        depth += 1;
      }
      const key = up
        ? `${up.className.split(" ")[0]}#${[...(up.parentElement?.children ?? [])].indexOf(up)}`
        : "(none)";
      box.set(key, (box.get(key) ?? 0) + 1);
    }
    const top = (m) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15);
    return { own: top(own), box: top(box), ...detached };
  });
  const kept = snapBefore ? diff(snapBefore, await takeSnapshot(cdp)) : undefined;

  const hiddenAfter = await hiddenTask();
  const wall = (Date.now() - wallStart) / 1000;
  const requests = await page.evaluate(() => ({ ...globalThis.__benchRequests }));
  const frameStats = await page.evaluate(() => {
    const b = globalThis.__benchFrames;
    b.stop();
    const sorted = [...b.frames].sort((x, y) => x - y);
    const q = (p) => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] * 10) / 10;
    const loaf = b.longTasks.filter((x) => x.type === "long-animation-frame").sort((x, y) => y.ms - x.ms);
    const lt = b.longTasks.filter((x) => x.type === "longtask").sort((x, y) => y.ms - x.ms);
    return {
      frames: sorted.length,
      frameP50: q(0.5),
      frameP95: q(0.95),
      frameP99: q(0.99),
      frameMax: Math.round(sorted.at(-1) ?? 0),
      framesOver33: sorted.filter((x) => x > 33.4).length,
      longestTaskMs: lt[0]?.ms ?? 0,
      longTasks: lt.length,
      longFrames: loaf.length,
      longestFrameMs: loaf[0]?.ms ?? 0,
      worstFrames: loaf.slice(0, 5),
    };
  });
  const name = `${run.sessions}-${run.mode}${LAG_DROPPED ? "-lagdropped" : ""}${HIDDEN ? `-hidden${HIDDEN}` : ""}${PROD ? "-prod" : ""}`;
  fs.writeFileSync(path.join(OUT, `${name}.cpuprofile`), JSON.stringify(profile));
  const delta = (key) => after[key] - before[key];
  const result = {
    run: name,
    openMs,
    firstPageBytes,
    taskMsPerSec: Math.round((delta("TaskDuration") * 1000) / wall),
    hiddenPages: HIDDEN,
    hiddenTaskMsPerSec: Math.round(((hiddenAfter - hiddenBefore) * 1000) / wall),
    scriptMsPerSec: Math.round((delta("ScriptDuration") * 1000) / wall),
    layoutMsPerSec: Math.round((delta("LayoutDuration") * 1000) / wall),
    styleMsPerSec: Math.round((delta("RecalcStyleDuration") * 1000) / wall),
    ...frameStats,
    heapGrowthMBPerMin: Math.round(((after.JSHeapUsedSize - heapBefore) / 1e6 / wall) * 60 * 10) / 10,
    heapAfterGcMB: Math.round(after.JSHeapUsedSize / 1e6),
    heapMB: Math.round(after.JSHeapUsedSize / 1e6),
    nodes: after.Nodes,
    requests,
    profile: summarize(profile),
    kept,
    series,
    census,
  };
  results.push(result);
  console.log(JSON.stringify(result, null, 1));
  await context.close();
}
await browser.close();
fs.writeFileSync(path.join(OUT, "results.json"), JSON.stringify(results, null, 1));
console.log("SUMMARY");
for (const r of results)
  console.log(
    `${r.run}: task ${r.taskMsPerSec} ms/s (+ hidden pages ${r.hiddenTaskMsPerSec} ms/s), script ${r.scriptMsPerSec} ms/s, heap +${r.heapGrowthMBPerMin} MB/min (after GC ${r.heapAfterGcMB} MB), frame p50/p95 ${r.frameP50}/${r.frameP95} ms, longest task ${r.longestTaskMs} ms (${r.longTasks} over 50), long frames ${r.longFrames}, style ${r.styleMsPerSec}, layout ${r.layoutMsPerSec}, profile busy ${r.profile.busyMs}/${r.profile.wallMs} ms, requests ${JSON.stringify(r.requests)}`,
  );
for (const r of results.filter((x) => x.series.length))
  console.log(
    `SERIES ${r.run}: ${r.series.map((x) => `${x.t}s ${x.heapMB}MB ${x.nodes}n ${x.listeners}l`).join(" | ")}`,
  );
for (const r of results)
  console.log(
    `CENSUS ${r.run}: li ${r.census.li}, keyed rows ${r.census.rows}; by class ${JSON.stringify(r.census.own)}; by container ${JSON.stringify(r.census.box)}`,
  );
for (const r of results.filter((x) => x.kept)) {
  console.log(`KEPT ${r.run}: ${r.kept.newCount} new objects, ${r.kept.newKB} KB`);
  for (const x of r.kept.byField.slice(0, 15)) console.log(`  field ${x.kb} KB ${x.count}x ${x.field}`);
  for (const x of r.kept.byHolder.slice(0, 12)) console.log(`  holder ${x.kb} KB ${x.count}x ${x.holder}`);
  for (const x of r.kept.byLabel.slice(0, 12)) console.log(`  type ${x.kb} KB ${x.count}x ${x.label}`);
}
stopServer();
process.exit(0);
