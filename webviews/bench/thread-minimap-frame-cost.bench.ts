// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Frame cost of the thread rail on a 2,000-row chat: no rail, the compact rail (the default) and the
// full-height minimap (ScrollMap.tsx, #22784), in the real pane (a production build of the pane's
// dev entry and a stand-in acpmux, as test/support/papercutChat.ts) on Chromium. Each arm runs idle,
// a steady wheel scroll and a streaming reply that appends rows; a Chrome trace of the renderer's main
// thread gives the busy time in each painted frame (scripting and rendering apart), its p50 and p95,
// and long tasks.
//   bun bench/thread-minimap-frame-cost.bench.ts [rounds=3] [turns=1000]
// An arm `<rail>+canvas` is that rail with the VS Code Minimap on (chatMinimap/ChatMinimap.tsx); its
// rounds pair with `<rail>`'s, run back to back in alternating order, and their p95 deltas are printed.
// ARMS=off,off+canvas SCENARIOS=scroll,stream picks arms and scenarios.
// The minimap's budget: the run exits 1 when any `+canvas` arm's median p95 delta over its rail
// exceeds MINIMAP_BUDGET_MS (1 ms) in scroll or stream, naming which. It needs a `+canvas` arm with
// its rail, both scenarios, and the minimap drawn; without them it exits 2. A bench, not a CI gate.
// The pane is a production build of its dev entry (vite's build() on vite.config.acpmux-pane.mjs), so
// React runs as it ships and the page joins the stand-in daemon from its #endpoint. The bench builds
// it unless PROD_DIR names one. The shipped pane (scripts/cmux-next/build-agent-pane-web.sh) is not
// one: it waits for the app's native bridge and never joins the daemon, so it is refused. When a page
// never shows the chat, the bench prints its console errors, failed requests and whether it joined.
// KEEP_TRACES=1 keeps the traces (and PROFILE=1's CPU profiles); otherwise they go.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";

const ROUNDS = Number(process.argv[2] ?? 3);
const TURNS = Number(process.argv[3] ?? 1000);
const ARMS = (process.env.ARMS?.split(",") ?? ["off", "off+canvas", "compact", "full"]) as readonly string[];
/// The VS Code Minimap's budget: its median p95 cost per frame, scrolling and streaming.
const MINIMAP_BUDGET_MS = 1;
const GATED = ["scroll", "stream"] as const;
const SCENARIOS = (process.env.SCENARIOS?.split(",") ?? ["idle", "scroll", "stream"]) as readonly (
  | "idle"
  | "scroll"
  | "stream"
)[];
const SECONDS = 4;
const PROFILE = process.env.PROFILE === "1";
const KEEP_TRACES = process.env.KEEP_TRACES === "1";
const webviews = path.resolve(import.meta.dir, "..");
const PROD_DIR = process.env.PROD_DIR;
if (PROD_DIR && !fs.existsSync(path.join(PROD_DIR, "index.html"))) {
  console.error(`thread-minimap-frame-cost: PROD_DIR ${PROD_DIR} has no index.html`);
  process.exit(2);
}
if (PROD_DIR && fs.existsSync(path.join(PROD_DIR, "pane.js"))) {
  console.error(
    `thread-minimap-frame-cost: PROD_DIR ${PROD_DIR} is the shipped pane (build-agent-pane-web.sh), which waits ` +
      "for the app's native bridge and never joins the stand-in daemon. Leave PROD_DIR unset (the bench builds " +
      "the dev entry) or give it vite's build of vite.config.acpmux-pane.mjs.",
  );
  process.exit(2);
}
/// The pane's dev entry, built for production when PROD_DIR names no build.
async function buildPane(): Promise<string> {
  if (PROD_DIR) return PROD_DIR;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "minimap-bench-pane-"));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true },
    logLevel: "error",
  });
  console.error(`thread-minimap-frame-cost: built the pane's dev entry into ${out}`);
  return out;
}
let prodDir = "";
/// Connections the stand-in daemon has had: a page that never joins it never shows the chat.
let joined = 0;

const { events, session } = papercutEvents({ turns: TURNS, running: false });
let socket: { send(data: string): void } | undefined;
let seq = events.length;
const hear = (dir: string, kind: string, msg: Record<string, unknown>) =>
  socket!.send(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/event",
      params: { sessionId: PAPERCUT_CHAT, seq: ++seq, at: Date.now(), dir, kind, msg },
    }),
  );
const answer = (method: string): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach":
      return { session, lastSeq: events.length, events, hasMore: false };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: seq };
    default:
      return null;
  }
};

/// The pane's URL, once its servers are up.
let url = "";

async function open(browser: Browser, arm: string): Promise<Page> {
  seq = events.length;
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  const [rail, extra] = arm.split("+");
  await page.addInitScript((rail) => {
    localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": rail }));
  }, rail);
  // What the page says while it loads, printed if the chat never shows.
  const said: string[] = [];
  page.on("console", (message) => {
    if (message.type() === "error" || message.type() === "warning") said.push(`console ${message.type()}: ${message.text()}`); // prettier-ignore
  });
  page.on("pageerror", (error) => said.push(`page error: ${error.message}`));
  page.on("requestfailed", (request) => said.push(`request failed: ${request.url()} ${request.failure()?.errorText ?? ""}`)); // prettier-ignore
  page.on("response", (response) => void (response.status() >= 400 && said.push(`HTTP ${response.status()}: ${response.url()}`))); // prettier-ignore
  const joinedBefore = joined;
  await page.goto(url);
  try {
    await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 180_000 });
  } catch (error) {
    console.error(
      `thread-minimap-frame-cost: the chat never showed (${arm}); the page ${joined > joinedBefore ? "joined" : "never joined"} the stand-in daemon.\n` +
        (said.length ? said.slice(0, 40).join("\n") : "(no console errors, failed requests or HTTP errors)"),
    );
    throw error;
  }
  // The host's `display` event, through dev.tsx's hook for a standalone daemon.
  if (extra === "canvas")
    await page.evaluate(() =>
      (window as { cmuxDevDisplay?: (value: unknown) => void }).cmuxDevDisplay?.({
        "agentPane.display.vscodeMinimap": true,
      }),
    );
  // EXTRA_CSS: a stylesheet to add, to try out where a cost comes from.
  if (process.env.EXTRA_CSS) await page.addStyleTag({ content: process.env.EXTRA_CSS });
  await page.waitForTimeout(1500);
  return page;
}

type TraceEvent = {
  name: string;
  cat: string;
  ph: string;
  ts: number;
  dur?: number;
  pid: number;
  tid: number;
  args?: any;
};
const RENDERING = new Set([
  "UpdateLayoutTree",
  "Layout",
  "PrePaint",
  "Paint",
  "PaintImage",
  "Layerize",
  "UpdateLayer",
  "UpdateLayerTree",
  "Commit",
  "HitTest",
  "IntersectionObserverController::computeIntersections",
  "ScrollLayer",
]);
const SCRIPTING = new Set([
  "FunctionCall",
  "EvaluateScript",
  "TimerFire",
  "FireAnimationFrame",
  "EventDispatch",
  "RunMicrotasks",
  "v8.run",
  "V8.Execute",
  "ResizeObserverController::DeliverObservations",
]);

/** Union length of [start, end) intervals inside each frame, the frames being [edges[i], edges[i+1]). */
function binned(intervals: [number, number][], edges: number[]): number[] {
  intervals.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const [a, b] of intervals) {
    const last = merged.at(-1);
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  const out = Array.from({ length: Math.max(0, edges.length - 1) }, () => 0);
  let first = 0;
  for (const [a, b] of merged) {
    while (first < out.length && edges[first + 1]! <= a) first++;
    for (let slot = first; slot < out.length && edges[slot]! < b; slot++)
      out[slot] += Math.max(0, Math.min(b, edges[slot + 1]!) - Math.max(a, edges[slot]!));
  }
  return out;
}
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))] ?? 0;
};

function analyze(file: string) {
  const all = (JSON.parse(fs.readFileSync(file, "utf8")) as { traceEvents: TraceEvent[] }).traceEvents;
  const mains = all.filter((e) => e.ph === "M" && e.name === "thread_name" && e.args?.name === "CrRendererMain");
  const mark = (message: string) => all.find((e) => e.name === "TimeStamp" && e.args?.data?.message === message);
  const begin = mark("bench-begin");
  const end = mark("bench-end");
  if (!begin || !end) throw new Error("no bench marks in the trace");
  const main = mains.find((m) => m.pid === begin.pid && m.tid === begin.tid) ?? mains[0]!;
  const on = all.filter((e) => e.pid === main.pid && e.tid === main.tid && e.ph === "X" && e.dur !== undefined);
  const start = begin.ts / 1000;
  const stop = end.ts / 1000;
  // The page stamps "f" in each frame's callbacks: a frame's work is what runs from one to the next.
  const edges = all
    .filter((e) => e.name === "TimeStamp" && e.args?.data?.message === "f" && e.pid === main.pid)
    .map((e) => e.ts / 1000)
    .filter((t) => t >= start && t <= stop)
    .sort((x, y) => x - y);
  const slots = edges.length - 1;
  const pick = (test: (e: TraceEvent) => boolean) =>
    on
      .filter((e) => test(e) && e.ts / 1000 < stop && (e.ts + e.dur!) / 1000 > start)
      .map((e) => [e.ts / 1000, (e.ts + e.dur!) / 1000] as [number, number]);
  const tasks = on.filter((e) => e.name === "ThreadControllerImpl::RunTask" || e.name === "RunTask");
  const busy = binned(
    pick((e) => e.name === "ThreadControllerImpl::RunTask" || e.name === "RunTask"),
    edges,
  );
  const script = binned(
    pick((e) => SCRIPTING.has(e.name)),
    edges,
  );
  const render = binned(
    pick((e) => RENDERING.has(e.name)),
    edges,
  );
  const gaps = edges.slice(1).map((t, i) => t - edges[i]!);
  const longTasks = tasks.filter((e) => e.ts / 1000 >= start && e.ts / 1000 < stop && e.dur! > 50_000).length;
  const mean = (v: number[]) => v.reduce((a, b) => a + b, 0) / Math.max(1, v.length);
  return {
    p50: pct(busy, 50),
    p95: pct(busy, 95),
    mean: mean(busy),
    scriptP95: pct(script, 95),
    renderP95: pct(render, 95),
    scriptMean: mean(script),
    renderMean: mean(render),
    longTasks,
    slots,
    frameP95: pct(gaps, 95),
  };
}

async function drive(page: Page, scenario: (typeof SCENARIOS)[number]) {
  if (scenario === "idle") {
    await page.waitForTimeout(SECONDS * 1000);
  } else if (scenario === "scroll") {
    await page.mouse.move(700, 400);
    const until = Date.now() + SECONDS * 1000;
    while (Date.now() < until) {
      await page.mouse.wheel(0, -120);
      await page.waitForTimeout(16);
    }
  } else {
    // A reply streams at about 30 chunks a second; every second a turn ends and the next prompt and
    // its reply start, so two rows append each second.
    const until = Date.now() + SECONDS * 1000;
    let n = TURNS;
    let turnAt = 0;
    while (Date.now() < until) {
      if (Date.now() - turnAt > 1000) {
        if (turnAt) hear("mux", "turn_result", { status: "completed" });
        n++;
        hear("mux", "user_message", { text: `Question ${n}` });
        hear("mux", "turn_started", {});
        turnAt = Date.now();
      }
      hear("in", "agent_message_chunk", {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: `word${n} and a few more tokens, ` },
          },
        },
      });
      await page.waitForTimeout(33);
    }
    hear("mux", "turn_result", { status: "completed" });
  }
}

const results: Record<string, ReturnType<typeof analyze>[]> = {};
/// The `+canvas` runs whose page drew no minimap (the setting never reached it): their deltas mean nothing.
const undrawn: string[] = [];
/// What the run acquired, released in reverse in the `finally` below, each on its own: one that
/// fails to close still lets the rest close.
const releases: Array<[string, () => unknown]> = [];
let tmp = "";
try {
  tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "minimap-bench-"));
  releases.push([
    "traces",
    () => {
      if (KEEP_TRACES) console.log(`traces kept in ${tmp}`);
      else fs.rmSync(tmp, { recursive: true, force: true });
    },
  ]);
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open() {
        joined += 1;
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string };
        socket = ws;
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);
  prodDir = await buildPane();
  if (!PROD_DIR) releases.push(["pane build", () => fs.rmSync(prodDir, { recursive: true, force: true })]);
  // The production build, served as static files.
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    // A path with no file (the dev entry's own host calls, /__dev-host/*) is a 404, not a thrown
    // ENOENT, which Bun reports and which ends the run with exit 1.
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(prodDir, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({ headless: true });
  releases.push(["browser", () => browser.close()]);
  // A first load warms the page's caches, so the first measured run is not the cold one.
  await (await open(browser, "off")).close();
  for (let round = 0; round < ROUNDS; round++) {
    // Arms interleave within each scenario, in alternating order, so drift hits every arm alike.
    for (const scenario of SCENARIOS) {
      for (const arm of round % 2 ? [...ARMS].reverse() : ARMS) {
        const page = await open(browser, arm);
        const drawn = await page.evaluate(() => ({
          scrollmap: document.querySelectorAll(".acpmux-scrollmap").length,
          minimap: document.querySelectorAll(".acpmux-minimap").length,
          marks: document.querySelectorAll(".acpmux-minimap__tick").length,
          canvas: document.querySelectorAll(".acpmux-chat-minimap canvas").length,
        }));
        const draws = () =>
          page.evaluate(() =>
            Number(document.querySelector<HTMLElement>(".acpmux-chat-minimap canvas")?.dataset.draws ?? 0),
          );
        const drawsBefore = await draws();
        if (round === 0) console.error(arm, scenario, JSON.stringify(drawn));
        const file = path.join(tmp, `${arm}-${scenario}-${round}.json`);
        await browser.startTracing(page, {
          path: file,
          categories: ["devtools.timeline", "toplevel", "blink.console", ...(process.env.TRACE_CATS?.split(",") ?? [])],
        });
        const cdp = PROFILE ? await page.context().newCDPSession(page) : undefined;
        if (cdp) {
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
          await cdp.send("Profiler.start");
        }
        await page.evaluate(() => {
          console.timeStamp("bench-begin");
          const w = window as unknown as { benchFrames?: boolean };
          w.benchFrames = true;
          const stamp = () => {
            if (!w.benchFrames) return;
            console.timeStamp("f");
            requestAnimationFrame(stamp);
          };
          requestAnimationFrame(stamp);
        });
        await drive(page, scenario);
        if (drawn.canvas) console.error(arm, scenario, `round ${round}: ${(await draws()) - drawsBefore} canvas draws`);
        else if (arm.endsWith("+canvas")) undrawn.push(`${arm}/${scenario} round ${round}`);
        await page.evaluate(() => {
          (window as unknown as { benchFrames?: boolean }).benchFrames = false;
          console.timeStamp("bench-end");
        });
        if (cdp) {
          const { profile } = await cdp.send("Profiler.stop");
          fs.writeFileSync(path.join(tmp, `${arm}-${scenario}-${round}.cpuprofile`), JSON.stringify(profile));
        }
        await browser.stopTracing();
        (results[`${arm}/${scenario}`] ??= []).push(analyze(file));
        await page.close();
      }
    }
  }
} finally {
  for (const [name, release] of releases.reverse()) {
    try {
      await release();
    } catch (error) {
      console.error(`thread-minimap-frame-cost: could not release the ${name}:`, error);
    }
  }
}

const median = (v: number[]) => pct(v, 50);
const fmt = (n: number) => n.toFixed(2).padStart(6);
console.log(`turns=${TURNS} (rows=${TURNS * 2}) rounds=${ROUNDS} seconds=${SECONDS} production build ${prodDir}`);
console.log("ms per frame:       busy p50  busy p95  mean  script p95 render p95 frame p95 frames longtasks");
for (const [key, runs] of Object.entries(results)) {
  console.log(
    `${key.padEnd(18)} ${fmt(median(runs.map((r) => r.p50)))}  ${fmt(median(runs.map((r) => r.p95)))}  ${fmt(median(runs.map((r) => r.mean)))}  ${fmt(median(runs.map((r) => r.scriptP95)))}  ${fmt(median(runs.map((r) => r.renderP95)))}  ${fmt(median(runs.map((r) => r.frameP95)))}  ${median(runs.map((r) => r.slots))}  ${runs.map((r) => r.longTasks).join(",")}`,
  );
}
// Each arm's extra cost over no rail.
for (const scenario of SCENARIOS) {
  for (const arm of ARMS) {
    if (arm === "off") continue;
    const a = results[`${arm}/${scenario}`];
    const b = results[`off/${scenario}`];
    if (!a || !b) continue;
    const delta = (pick: (r: (typeof a)[number]) => number) => fmt(median(a.map(pick)) - median(b.map(pick)));
    console.log(
      `${arm} - off ${scenario}: p50 ${delta((r) => r.p50)} p95 ${delta((r) => r.p95)} mean ${delta((r) => r.mean)}`,
    );
  }
}
// A `+canvas` arm against its rail alone, round by round: the median p95 delta and its spread, and
// the budget.
const gated = ARMS.filter((each) => each.endsWith("+canvas") && ARMS.includes(each.split("+")[0]!));
const missing = [
  ...(gated.length === 0 ? ["a `<rail>+canvas` arm with its rail (ARMS=off,off+canvas)"] : []),
  ...GATED.filter((scenario) => !SCENARIOS.includes(scenario)).map((scenario) => `the ${scenario} scenario`),
];
const over: string[] = [];
for (const scenario of SCENARIOS) {
  for (const arm of gated) {
    const a = results[`${arm}/${scenario}`];
    const b = results[`${arm.split("+")[0]}/${scenario}`];
    if (!a || !b) continue;
    const deltas = a.map((run, index) => run.p95 - b[index]!.p95);
    const under = deltas.filter((delta) => delta < MINIMAP_BUDGET_MS).length;
    console.log(
      `${arm} paired ${scenario}: p95 delta median ${fmt(median(deltas))} min ${fmt(Math.min(...deltas))} max ${fmt(Math.max(...deltas))}; under ${MINIMAP_BUDGET_MS} ms in ${under}/${deltas.length}; deltas ${deltas.map((delta) => delta.toFixed(2)).join(" ")}`,
    );
    if ((GATED as readonly string[]).includes(scenario) && median(deltas) > MINIMAP_BUDGET_MS)
      over.push(`${arm} ${scenario}: median p95 delta ${median(deltas).toFixed(2)} ms`);
  }
}
if (missing.length || undrawn.length) {
  console.error(
    `thread-minimap-frame-cost: the minimap budget could not be checked: ${[
      ...missing.map((what) => `missing ${what}`),
      ...(undrawn.length ? [`no minimap drawn in ${undrawn.join(", ")}`] : []),
    ].join("; ")}`,
  );
  process.exit(2);
}
if (over.length) {
  console.error(`thread-minimap-frame-cost: over the ${MINIMAP_BUDGET_MS} ms budget: ${over.join("; ")}`);
  process.exit(1);
}
console.log(`minimap budget: within ${MINIMAP_BUDGET_MS} ms (median p95 delta) in ${GATED.join(" and ")}`);
