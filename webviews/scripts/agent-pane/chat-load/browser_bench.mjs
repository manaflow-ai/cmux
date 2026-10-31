// Chat-load benchmark, page stage (perf100). The shipped agent pane bundle
// (scripts/cmux-next/build-agent-pane-web.sh --out DIR), served over loopback, in headless
// Chromium or WebKit, opens each fixture chat (fixture.ts) from a real acpmux daemon
// (daemon_bench.py --keep-pidfile), and the mock chat of the in-page mock daemon.
//
// The page talks to acpmux over its WebSocket transport (as the browser dev slot does); in the
// app the host relays the same JSON frames over the native bridge. Per chat it reports, on the
// page clock from the moment the open starts (navigation for a cold open, the select call for a
// switch):
//   first_paint_ms   the first animation frame whose DOM shows the chat's newest message;
//   interactive_ms   the end of the last long task (>50 ms) before 500 ms with none, after that;
//   bytes_in         the JSON the page received (UTF-16 units of every acpmux reply and event);
//   requests         the JSON-RPC requests the page sent;
//   script_ms, layout_ms, style_ms, task_ms (Chromium only, CDP Performance.getMetrics);
//   heap_mb          the JS heap in use once interactive (Chromium only);
//   dom_nodes        DOM nodes once interactive;
//   daemon_cpu_ms    the acpmux daemon's CPU time during the open (from /proc).
// Then (--scroll) it scrolls to the first message and reports the time and bytes it took.
//
//   node browser_bench.mjs --pane DIR --fixture FIXTURE_JSON --endpoint ws://127.0.0.1:P --token T
//        --daemon-pid PID --out OUT_JSON [--engine chromium|webkit] [--repeat 3] [--scroll]
//        [--mock-turns 100,1000,10000] [--port 4319]
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import pw from "playwright";

const arg = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const has = (name) => process.argv.includes(`--${name}`);
const paneDir = arg("pane");
const fixture = arg("fixture") ? JSON.parse(fs.readFileSync(arg("fixture"), "utf8")) : { sessions: [] };
const endpoint = arg("endpoint");
const token = arg("token");
const daemonPid = arg("daemon-pid");
const out = arg("out", "browser.json");
const engine = arg("engine", "chromium");
const repeat = Number(arg("repeat", "3"));
const port = Number(arg("port", "4319"));
const mockTurns = (arg("mock-turns", "") || "").split(",").filter(Boolean).map(Number);
const onlySessions = arg("sessions") ? new Set(arg("sessions").split(",").map(Number)) : undefined;

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

const daemonCpu = () => {
  if (!daemonPid) return 0;
  const parts = fs.readFileSync(`/proc/${daemonPid}/stat`, "utf8").split(")").at(-1).trim().split(/\s+/);
  return ((Number(parts[11]) + Number(parts[12])) * 1000) / 100;
};

// Before any pane script: the native host shim (the dev host's replies) and the probes.
function shim(config) {
  const probe = (window.__chatLoad = { marker: config.marker, firstPaint: undefined, longTasks: [], start: 0 });
  probe.bytesIn = 0;
  probe.requests = 0;
  probe.sentEvents = [];
  const Native = window.WebSocket;
  window.WebSocket = class extends Native {
    constructor(...args) {
      super(...args);
      this.addEventListener("message", (event) => {
        probe.bytesIn += typeof event.data === "string" ? event.data.length : 0;
      });
    }
    send(data) {
      probe.requests += 1;
      try {
        const method = JSON.parse(String(data)).method;
        if (method === "_acpmux/events") probe.sentEvents.push(Math.round(performance.now()));
      } catch {
        // not JSON
      }
      return super.send(data);
    }
  };
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) probe.longTasks.push([entry.startTime, entry.startTime + entry.duration]);
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // WebKit has no long task timing; interactive falls back to frame gaps below.
  }
  // Frame gaps over 50 ms count as long tasks too (WebKit, and any engine's missed frames).
  let last = 0;
  const watch = (now) => {
    if (last && now - last > 50) probe.longTasks.push([last, now]);
    last = now;
    if (probe.marker && probe.firstPaint === undefined) {
      const scroller = document.querySelector(".acpmux-scroll");
      if (scroller && scroller.textContent.includes(probe.marker)) probe.firstPaint = now;
    }
    requestAnimationFrame(watch);
  };
  requestAnimationFrame(watch);
  const reply = (request) => {
    const method = String(request.method).replace(/^cmux\.agent\./, "");
    switch (method) {
      case "handshake":
      case "ready":
        return config.mock
          ? { ok: true, value: { protocolVersion: 1, transport: "mock" } }
          : {
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint: config.endpoint,
                token: config.token,
                sessionId: config.sessionId,
                cwd: "/tmp",
                linkScheme: "cmux-dev",
              },
            };
      case "acp.trust.get":
        return { ok: true, value: { cwd: request.params?.cwd ?? "/tmp", level: "trusted" } };
      case "pane.context":
        return { ok: true, value: { cwd: "/tmp", urls: [] } };
      case "pane.painted":
        probe.panePainted ??= performance.now();
        return { ok: true, value: null };
      default:
        return { ok: true, value: null };
    }
  };
  window.webkit = { messageHandlers: { agentSession: { postMessage: (request) => Promise.resolve(reply(request)) } } };
}

/// The interactive point: the end of the last long task that starts before a 500 ms quiet span,
/// counted from the first paint.
function interactiveAt(longTasks, firstPaint) {
  let at = firstPaint;
  for (const [start, end] of [...longTasks].sort((a, b) => a[0] - b[0])) {
    if (start > at + 500) break;
    at = Math.max(at, end);
  }
  return at;
}

const browser = await pw[engine].launch();
const results = { stage: "page", engine, sessions: [], mock: [] };

async function metrics(page, cdp) {
  if (!cdp) return {};
  const { metrics: list } = await cdp.send("Performance.getMetrics");
  const m = Object.fromEntries(list.map((entry) => [entry.name, entry.value]));
  return {
    script_ms: Math.round(m.ScriptDuration * 1000),
    layout_ms: Math.round(m.LayoutDuration * 1000),
    style_ms: Math.round(m.RecalcStyleDuration * 1000),
    task_ms: Math.round(m.TaskDuration * 1000),
    heap_mb: Math.round((m.JSHeapUsedSize / 1e6) * 10) / 10,
  };
}

async function settle(page, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const state = await page.evaluate(() => {
      const p = window.__chatLoad;
      return { firstPaint: p.marker ? p.firstPaint : p.panePainted, now: performance.now(), longTasks: p.longTasks };
    });
    if (state.firstPaint !== undefined) {
      const at = interactiveAt(state.longTasks, state.firstPaint);
      if (state.now - at >= 500) return { firstPaint: state.firstPaint, interactive: at };
    }
    if (Date.now() > deadline) return { firstPaint: state.firstPaint, interactive: undefined, timedOut: true };
    await page.waitForTimeout(100);
  }
}

/// Scrolls the transcript to its top until the first message shows (the pane loads older pages
/// as the reader nears the top). Returns the time and the bytes it took.
async function scrollToFirst(page, firstMarker, timeoutMs) {
  const t0 = Date.now();
  const bytes0 = await page.evaluate(() => window.__chatLoad.bytesIn);
  const req0 = await page.evaluate(() => window.__chatLoad.requests);
  let found = false;
  while (Date.now() - t0 < timeoutMs) {
    found = await page.evaluate((marker) => {
      const scroller = document.querySelector(".acpmux-scroll");
      if (!scroller) return false;
      scroller.scrollTop = 0;
      return scroller.textContent.includes(marker);
    }, firstMarker);
    if (found) break;
    await page.waitForTimeout(50);
  }
  const trace = has("trace-scroll")
    ? await page.evaluate(async () => {
        const log = window.cmuxAcpmuxDebug.acpLog({ limit: 2000 });
        const replies = (log.entries ?? [])
          .filter((entry) => entry.kind === "response" && entry.method === "_acpmux/events")
          .map((entry) => [entry.at, entry.latencyMs, entry.size]);
        const state = window.cmuxAcpmuxDebug.chatState();
        const sentBefore = window.__chatLoad.sentEvents.length;
        let manual;
        try {
          await window.cmuxAcpmuxActions["chat.history"]();
          const after = window.cmuxAcpmuxDebug.chatState();
          manual = {
            sent: window.__chatLoad.sentEvents.length - sentBefore,
            rows: after.rows,
            historyFrom: after.historyFrom,
          };
        } catch (error) {
          manual = String(error);
        }
        const scroller = document.querySelector(".acpmux-scroll");
        return {
          sent: window.__chatLoad.sentEvents.slice(-80),
          replies: replies.slice(-80),
          now: Math.round(performance.now()),
          rows: state.rows,
          canLoadOlder: state.canLoadOlder,
          historyFrom: state.historyFrom,
          scroll: scroller && [scroller.scrollTop, scroller.clientHeight, scroller.scrollHeight],
          manual,
        };
      })
    : undefined;
  return {
    found,
    ...(trace ? { trace } : {}),
    ms: Date.now() - t0,
    bytes_in: (await page.evaluate(() => window.__chatLoad.bytesIn)) - bytes0,
    requests: (await page.evaluate(() => window.__chatLoad.requests)) - req0,
  };
}

async function coldOpen(config, label) {
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 1100, height: 900 } });
  const page = await context.newPage();
  const cdp = engine === "chromium" ? await context.newCDPSession(page) : undefined;
  if (cdp) await cdp.send("Performance.enable");
  await page.addInitScript(shim, config);
  const cpu0 = daemonCpu();
  await page.goto(`${origin}/index.html`);
  const s = await settle(page, 120_000);
  const probe = await page.evaluate(() => ({
    bytesIn: window.__chatLoad.bytesIn,
    requests: window.__chatLoad.requests,
    panePainted: window.__chatLoad.panePainted,
    domNodes: document.getElementsByTagName("*").length,
    rows: document.querySelectorAll(".acpmux-scroll [data-row-id], .acpmux-scroll [data-index]").length,
  }));
  const row = {
    label,
    first_paint_ms: s.firstPaint === undefined ? null : Math.round(s.firstPaint),
    interactive_ms: s.interactive === undefined ? null : Math.round(s.interactive),
    pane_painted_ms: probe.panePainted === undefined ? null : Math.round(probe.panePainted),
    timed_out: !!s.timedOut,
    bytes_in: probe.bytesIn,
    requests: probe.requests,
    dom_nodes: probe.domNodes,
    daemon_cpu_ms: Math.round(daemonCpu() - cpu0),
    ...(await metrics(page, cdp)),
  };
  return { row, page, context };
}

const median = (values) => {
  const v = values.filter((x) => typeof x === "number").sort((a, b) => a - b);
  return v.length ? v[Math.floor((v.length - 1) / 2)] : null;
};
const summarize = (runs) => {
  const keys = Object.keys(runs[0]).filter((k) => typeof runs[0][k] === "number");
  return Object.fromEntries(keys.map((k) => [k, median(runs.map((r) => r[k]))]));
};

/// A CPU profile of what the page runs: `ms` of scrolling to the top (older pages) after a cold
/// open of `s`, or the cold open itself. Prints the functions with the most self time.
async function profile(s, what, ms) {
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 1100, height: 900 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
  await page.addInitScript(shim, { endpoint, token, sessionId: s.id, marker: s.lastMarker });
  if (what === "open") await cdp.send("Profiler.start");
  await page.goto(`${origin}/index.html`);
  await settle(page, 120_000);
  if (what === "scroll") {
    await cdp.send("Profiler.start");
    await scrollToFirst(page, "Turn 0: why does step 0", ms);
  }
  const { profile: prof } = await cdp.send("Profiler.stop");
  const self = new Map();
  const byId = new Map(prof.nodes.map((n) => [n.id, n]));
  const dt = prof.timeDeltas;
  prof.samples.forEach((id, i) => {
    const f = byId.get(id).callFrame;
    const key = `${f.functionName || "(anon)"} ${f.url.split("/").pop()}:${f.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + (dt[i] ?? 0) / 1000);
  });
  const total = [...self.values()].reduce((a, b) => a + b, 0);
  const top = [...self.entries()].sort((a, b) => b[1] - a[1]).slice(0, 45);
  console.log(`== profile ${what} ${s.turns} turns: ${Math.round(total)} ms sampled`);
  for (const [key, value] of top) console.log(`${value.toFixed(1).padStart(9)} ms  ${key}`);
  await context.close();
}

if (arg("profile")) {
  const [what, turns, ms] = arg("profile").split(":");
  const s = fixture.sessions.find((entry) => entry.turns === Number(turns));
  await profile(s, what, Number(ms ?? "10000"));
  await browser.close();
  server.close();
  process.exit(0);
}

// One cold open first, not counted: the first page of a browser pays for its process and caches.
if (fixture.sessions.length) {
  const s = fixture.sessions[0];
  const { context } = await coldOpen({ endpoint, token, sessionId: s.id, marker: s.lastMarker }, "warmup");
  await context.close();
}

for (const s of fixture.sessions) {
  if (onlySessions && !onlySessions.has(s.turns)) continue;
  const runs = [];
  let scroll;
  for (let i = 0; i < repeat; i += 1) {
    const { row, page, context } = await coldOpen(
      { endpoint, token, sessionId: s.id, marker: s.lastMarker },
      `acpmux ${s.turns} turns`,
    );
    runs.push(row);
    if (i === repeat - 1 && has("scroll") && s.turns <= Number(arg("scroll-max-turns", "1000000")))
      scroll = await scrollToFirst(page, "Turn 0: why does step 0", Number(arg("scroll-timeout", "600000")));
    await context.close();
  }
  const entry = {
    turns: s.turns,
    records: s.records,
    log_mb: Math.round(s.bytes / 1e5) / 10,
    runs,
    median: summarize(runs),
    scroll,
  };
  results.sessions.push(entry);
  console.log(JSON.stringify({ turns: s.turns, median: entry.median, scroll }));
}

// A switch: one page, already open on another chat, selects each fixture chat (warm: the page
// and its connection are up), as a click in the session list does.
if (has("switch") && fixture.sessions.length > 1) {
  const home = fixture.sessions[0];
  for (const s of fixture.sessions) {
    if (onlySessions && !onlySessions.has(s.turns)) continue;
    const runs = [];
    for (let i = 0; i < repeat; i += 1) {
      const other = s === home ? fixture.sessions[1] : home;
      const { page, context } = await coldOpen(
        { endpoint, token, sessionId: other.id, marker: other.lastMarker },
        "home",
      );
      const cdp = engine === "chromium" ? await context.newCDPSession(page) : undefined;
      if (cdp) await cdp.send("Performance.enable");
      const before = await metrics(page, cdp);
      const cpu0 = daemonCpu();
      const t = await page.evaluate(
        ({ id, marker }) => {
          const p = window.__chatLoad;
          p.marker = marker;
          p.firstPaint = undefined;
          p.longTasks = [];
          p.bytesIn = 0;
          p.requests = 0;
          const called = performance.now();
          window.cmuxAcpmuxDebug.selectSession(id);
          return called;
        },
        { id: s.id, marker: s.lastMarker },
      );
      const st = await settle(page, 120_000);
      const after = await metrics(page, cdp);
      const probe = await page.evaluate(() => ({
        bytesIn: window.__chatLoad.bytesIn,
        requests: window.__chatLoad.requests,
      }));
      runs.push({
        first_paint_ms: st.firstPaint === undefined ? null : Math.round(st.firstPaint - t),
        interactive_ms: st.interactive === undefined ? null : Math.round(st.interactive - t),
        bytes_in: probe.bytesIn,
        requests: probe.requests,
        daemon_cpu_ms: Math.round(daemonCpu() - cpu0),
        ...Object.fromEntries(Object.entries(after).map(([k, v]) => [k, k === "heap_mb" ? v : v - (before[k] ?? 0)])),
      });
      await context.close();
    }
    results.switch ??= [];
    results.switch.push({ turns: s.turns, runs, median: summarize(runs) });
    console.log(JSON.stringify({ switch: s.turns, median: summarize(runs) }));
  }
}

// The mock chat: the pane's in-page mock daemon (CMUX_NEXT_AGENT_PANE_MOCK=1 / showcase).
if (has("mock")) {
  const runs = [];
  for (let i = 0; i < repeat; i += 1) {
    const { row, context } = await coldOpen(
      { mock: true, marker: arg("mock-marker", "") || undefined },
      "mock default",
    );
    runs.push(row);
    await context.close();
  }
  results.mock.push({ label: "mock default chat (cold page)", runs, median: summarize(runs) });
  console.log(JSON.stringify({ mock: "default", median: summarize(runs) }));
}
for (const turns of mockTurns) {
  const runs = [];
  let scroll;
  for (let i = 0; i < repeat; i += 1) {
    const context = await browser.newContext({ bypassCSP: true, viewport: { width: 1100, height: 900 } });
    const page = await context.newPage();
    await page.addInitScript(shim, { mock: true });
    await page.goto(`${origin}/index.html`);
    await page.waitForFunction(() => !!window.cmuxAcpmuxDebug, null, { timeout: 60_000 });
    await page.waitForTimeout(1000);
    const cdp = engine === "chromium" ? await context.newCDPSession(page) : undefined;
    if (cdp) await cdp.send("Performance.enable");
    const before = await metrics(page, cdp);
    // Seed, then measure from the select: loadSeed records the session in the mock daemon
    // (seed_ms) and selects it at once.
    const t = await page.evaluate(async (count) => {
      const p = window.__chatLoad;
      p.marker = `Done with turn ${count - 1}`;
      p.firstPaint = undefined;
      p.longTasks = [];
      p.bytesIn = 0;
      p.requests = 0;
      const called = performance.now();
      const seeded = await window.cmuxAcpmuxDebug.loadSeed(count);
      return { called, seed_ms: seeded.seed_ms };
    }, turns);
    const s = await settle(page, 120_000);
    const after = await metrics(page, cdp);
    const start = t.called + t.seed_ms;
    const row = {
      label: `mock ${turns} turns`,
      first_paint_ms: s.firstPaint === undefined ? null : Math.round(s.firstPaint - start),
      interactive_ms: s.interactive === undefined ? null : Math.round(s.interactive - start),
      seed_ms: Math.round(t.seed_ms),
      timed_out: !!s.timedOut,
      dom_nodes: await page.evaluate(() => document.getElementsByTagName("*").length),
      ...Object.fromEntries(Object.entries(after).map(([k, v]) => [k, k === "heap_mb" ? v : v - (before[k] ?? 0)])),
    };
    runs.push(row);
    if (i === repeat - 1 && has("scroll") && turns <= Number(arg("scroll-max-turns", "1000000")))
      scroll = await scrollToFirst(page, "Turn 0: why does step 0", Number(arg("scroll-timeout", "600000")));
    await context.close();
  }
  results.mock.push({ label: `mock ${turns} turns (loadSeed)`, turns, runs, median: summarize(runs), scroll });
  console.log(JSON.stringify({ mock: turns, median: summarize(runs), scroll }));
}

fs.writeFileSync(out, JSON.stringify(results, null, 1));
await browser.close();
server.close();
