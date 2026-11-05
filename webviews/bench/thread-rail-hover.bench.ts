// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Hover sweep over the compact thread rail (threadMinimap/ThreadMinimap.tsx) on a 1,000-prompt chat,
// in the real pane (a production build of its dev entry and a stand-in acpmux, as
// thread-minimap-frame-cost.bench.ts) on Chromium. The pointer sweeps up and down the rail's drawn
// ticks at a person's speed (STEP_PX every STEP_MS, 2 px per 8 ms by default, so a 10 px row changes
// every 40 ms) for SECONDS. A Chrome trace of the renderer's main thread gives the busy time in each
// frame (scripting and rendering apart, and layout forced from script), its p50, p95 and max, and long
// tasks. The page itself measures, for each row the pointer reaches, the time from the pointermove that
// crossed into it to the first animation frame whose rail shows it active and whose card shows its
// prompt (row latency), and the Event Timing durations (input to next paint) of the ticks'
// pointerover/pointerenter.
//   bun bench/thread-rail-hover.bench.ts [rounds=3] [turns=1000]
// ARMS=plain,seethrough: `seethrough` sets data-cmux-see-through on the root, as the app's see-through
// Chromium page does, so the card's see-through blur (ui/glass/seeThroughBlur.ts) filters the transcript.
// PROFILE=1 also takes a CPU profile of each sweep and prints the top self-time functions (it builds the
// pane unminified so the names read, unless MINIFY=1). KEEP_TRACES=1 keeps the traces and profiles.
// FAST_CHECKS_OUT, when set (cmux-ci), receives the last round's trace and profile of each arm.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";

const ROUNDS = Number(process.argv[2] ?? 3);
const TURNS = Number(process.argv[3] ?? 1000);
const ARMS = (process.env.ARMS?.split(",") ?? ["plain", "seethrough"]) as readonly string[];
const SECONDS = Number(process.env.SECONDS ?? 4);
const STEP_PX = Number(process.env.STEP_PX ?? 2);
const STEP_MS = Number(process.env.STEP_MS ?? 8);
const PROFILE = process.env.PROFILE === "1";
const MINIFY = process.env.MINIFY ? process.env.MINIFY === "1" : !PROFILE;
const KEEP_TRACES = process.env.KEEP_TRACES === "1";
const OUT = process.env.FAST_CHECKS_OUT;
const ROW_PITCH = 10;
const webviews = path.resolve(import.meta.dir, "..");
const PROD_DIR = process.env.PROD_DIR;
const log = (...args: unknown[]) => console.error("thread-rail-hover:", ...args);

async function buildPane(): Promise<string> {
  if (PROD_DIR) return PROD_DIR;
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "rail-hover-pane-"));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, minify: MINIFY },
    logLevel: "error",
  });
  log(`built the pane's dev entry into ${out} (minify ${MINIFY})`);
  return out;
}

const { events, session } = papercutEvents({ turns: TURNS, running: false });
const answer = (method: string): unknown => {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: 1,
        _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
      };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach":
      return { session, lastSeq: events.length, events, hasMore: false };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
};
let url = "";

async function open(browser: Browser, arm: string): Promise<Page> {
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  await page.addInitScript((seeThrough) => {
    localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": "compact" }));
    if (seeThrough) document.documentElement.setAttribute("data-cmux-see-through", "");
  }, arm === "seethrough");
  const said: string[] = [];
  page.on("console", (m) => void ((m.type() === "error" || m.type() === "warning") && said.push(`${m.type()}: ${m.text()}`))); // prettier-ignore
  page.on("pageerror", (error) => said.push(`page error: ${error.message}`));
  await page.goto(url);
  try {
    await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 180_000 });
    await page.locator(".acpmux-minimap__tick").first().waitFor({ timeout: 30_000 });
  } catch (error) {
    log(`the chat or its rail never showed (${arm})\n${said.slice(0, 40).join("\n")}`);
    throw error;
  }
  if (arm === "seethrough")
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
  await page.waitForTimeout(1500);
  return page;
}

type TraceEvent = { name: string; cat: string; ph: string; ts: number; dur?: number; pid: number; tid: number; args?: any }; // prettier-ignore
const RENDERING = new Set(["UpdateLayoutTree", "Layout", "PrePaint", "Paint", "PaintImage", "Layerize", "UpdateLayer", "UpdateLayerTree", "Commit", "HitTest", "IntersectionObserverController::computeIntersections"]); // prettier-ignore
const SCRIPTING = new Set(["FunctionCall", "EvaluateScript", "TimerFire", "FireAnimationFrame", "EventDispatch", "RunMicrotasks", "v8.run", "V8.Execute", "ResizeObserverController::DeliverObservations"]); // prettier-ignore

function merge(intervals: [number, number][]): [number, number][] {
  intervals.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const [a, b] of intervals) {
    const last = merged.at(-1);
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  return merged;
}
function binned(intervals: [number, number][], edges: number[]): number[] {
  const out = Array.from({ length: Math.max(0, edges.length - 1) }, () => 0);
  let first = 0;
  for (const [a, b] of merge(intervals)) {
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
const sum = (v: number[]) => v.reduce((a, b) => a + b, 0);
const overlapOf = (a: [number, number], within: [number, number][]) => {
  let total = 0;
  for (const [x, y] of within) total += Math.max(0, Math.min(a[1], y) - Math.max(a[0], x));
  return total;
};

function analyze(file: string) {
  const all = (JSON.parse(fs.readFileSync(file, "utf8")) as { traceEvents: TraceEvent[] }).traceEvents;
  const mark = (message: string) => all.find((e) => e.name === "TimeStamp" && e.args?.data?.message === message);
  const begin = mark("bench-begin");
  const end = mark("bench-end");
  if (!begin || !end) throw new Error("no bench marks in the trace");
  const on = all.filter((e) => e.pid === begin.pid && e.tid === begin.tid && e.ph === "X" && e.dur !== undefined);
  const start = begin.ts / 1000;
  const stop = end.ts / 1000;
  const edges = all
    .filter((e) => e.name === "TimeStamp" && e.args?.data?.message === "f" && e.pid === begin.pid)
    .map((e) => e.ts / 1000)
    .filter((t) => t >= start && t <= stop)
    .sort((x, y) => x - y);
  const inside = (e: TraceEvent) => e.ts / 1000 < stop && (e.ts + e.dur!) / 1000 > start;
  const span = (e: TraceEvent) => [e.ts / 1000, (e.ts + e.dur!) / 1000] as [number, number];
  const pick = (test: (e: TraceEvent) => boolean) => on.filter((e) => test(e) && inside(e)).map(span);
  const isTask = (e: TraceEvent) => e.name === "ThreadControllerImpl::RunTask" || e.name === "RunTask";
  const busy = binned(pick(isTask), edges);
  const script = binned(
    pick((e) => SCRIPTING.has(e.name)),
    edges,
  );
  const render = binned(
    pick((e) => RENDERING.has(e.name)),
    edges,
  );
  // Layout and style recalcs that run inside script are forced (a read after a write).
  const scriptSpans = merge(pick((e) => SCRIPTING.has(e.name)));
  const layouts = on.filter((e) => (e.name === "Layout" || e.name === "UpdateLayoutTree") && inside(e));
  let forcedMs = 0;
  let forcedCount = 0;
  let layoutMs = 0;
  let styleMs = 0;
  for (const e of layouts) {
    const s = span(e);
    if (e.name === "Layout") layoutMs += s[1] - s[0];
    else styleMs += s[1] - s[0];
    const forced = overlapOf(s, scriptSpans);
    if (forced > (s[1] - s[0]) / 2) {
      forcedMs += s[1] - s[0];
      forcedCount++;
    }
  }
  const paintMs = sum(pick((e) => e.name === "Paint" || e.name === "PaintImage" || e.name === "PrePaint").map(([a, b]) => b - a)); // prettier-ignore
  const elements = on
    .filter((e) => e.name === "UpdateLayoutTree" && inside(e))
    .map((e) => Number(e.args?.elementCount ?? e.args?.data?.elementCount ?? 0));
  const longTasks = on.filter((e) => isTask(e) && e.ts / 1000 >= start && e.ts / 1000 < stop && e.dur! > 50_000).length; // prettier-ignore
  const gaps = edges.slice(1).map((t, i) => t - edges[i]!);
  return {
    p50: pct(busy, 50),
    p95: pct(busy, 95),
    max: Math.max(0, ...busy),
    scriptP95: pct(script, 95),
    renderP95: pct(render, 95),
    frameP95: pct(gaps, 95),
    frames: edges.length - 1,
    over16: busy.filter((b) => b > 16.7).length,
    longTasks,
    forcedMs,
    forcedCount,
    layoutMs,
    styleMs,
    paintMs,
    styleElementsP95: pct(elements, 95),
    styleElementsMax: Math.max(0, ...elements),
  };
}

type Latency = { rows: number; reached: number; p50: number; p95: number; max: number; enterP95: number; enterMax: number; slowEnters: number; enters: number }; // prettier-ignore

/// Installs the page's own probes: the row the pointer is on (from the list's rect, read once), the
/// pointermove that first reached each row, and per frame whether the rail and card show it.
async function probe(page: Page) {
  await page.evaluate((pitch) => {
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const box = list.getBoundingClientRect();
    const scrollTop = list.scrollTop;
    const w = window as any;
    w.benchRows = [] as { row: number; at: number; seen?: number }[];
    w.benchEnters = [] as number[];
    let last = -1;
    window.addEventListener(
      "pointermove",
      (event) => {
        if (event.clientX < box.left || event.clientX > box.right) return;
        const row = Math.floor((event.clientY - box.top + scrollTop) / pitch);
        if (row === last) return;
        last = row;
        w.benchRows.push({ row, at: event.timeStamp });
      },
      { capture: true },
    );
    // Event Timing: input to the next paint, for durations of 16 ms and up (its floor).
    new PerformanceObserver((entries) => {
      for (const entry of entries.getEntries())
        if (entry.name === "pointerover" || entry.name === "pointerenter") w.benchEnters.push(entry.duration);
    }).observe({
      type: "event",
      durationThreshold: 16,
      buffered: false,
    } as PerformanceObserverInit);
    w.benchEnterCount = 0;
    list.addEventListener("pointerover", () => (w.benchEnterCount += 1), { capture: true });
    const check = (now: number) => {
      if (!w.benchFrames) return;
      const pending = w.benchRows.filter((r: { seen?: number }) => r.seen === undefined);
      if (pending.length) {
        const activeTick = document.querySelector<HTMLElement>('.acpmux-minimap__tick[data-tone="active"]');
        const active = activeTick ? Number(activeTick.dataset.tick) : -1;
        const card = document.querySelector(".acpmux-minimap__card .acpmux-minimap__prompt")?.textContent ?? "";
        const prompt = activeTick?.getAttribute("aria-label") ?? "";
        for (const r of pending) {
          // A row the pointer passed and left before any frame showed it counts as reached by the
          // frame that shows a later row.
          const later = w.benchRows.some((o: { row: number; at: number }) => o.at > r.at && o.row === active);
          if ((active === r.row && card && prompt.includes(card)) || later) r.seen = now;
        }
      }
    };
    w.benchCheck = check;
  }, ROW_PITCH);
}

async function sweep(page: Page) {
  const ticks = await page.evaluate(() => {
    const rail = document.querySelector<HTMLElement>(".acpmux-minimap__list")!.getBoundingClientRect();
    const drawn = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")]
      .map((t) => t.getBoundingClientRect())
      .filter((r) => r.bottom > rail.top && r.top < rail.bottom && r.height > 0);
    return {
      x: drawn[0]!.left + drawn[0]!.width / 2,
      top: Math.max(rail.top, Math.min(...drawn.map((r) => r.top))) + 4,
      bottom: Math.min(rail.bottom, Math.max(...drawn.map((r) => r.bottom))) - 4,
    };
  });
  await page.mouse.move(ticks.x + 200, ticks.top);
  await page.mouse.move(ticks.x, ticks.top);
  await page.waitForTimeout(300);
  await probe(page);
  await page.evaluate(() => {
    console.timeStamp("bench-begin");
    const w = window as any;
    w.benchFrames = true;
    const stamp = (now: number) => {
      if (!w.benchFrames) return;
      console.timeStamp("f");
      w.benchCheck(now);
      requestAnimationFrame(stamp);
    };
    requestAnimationFrame(stamp);
  });
  const t0 = Date.now();
  let y = ticks.top;
  let dir = 1;
  for (let step = 0; Date.now() - t0 < SECONDS * 1000; step++) {
    y += dir * STEP_PX;
    if (y >= ticks.bottom || y <= ticks.top) dir = -dir;
    await page.mouse.move(ticks.x, y);
    const wait = t0 + (step + 1) * STEP_MS - Date.now();
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  }
  await page.waitForTimeout(200);
  const latency = (await page.evaluate(() => {
    const w = window as any;
    const rows = w.benchRows as { row: number; at: number; seen?: number }[];
    const seen = rows.filter((r) => r.seen !== undefined).map((r) => r.seen! - r.at);
    const sorted = [...seen].sort((a, b) => a - b);
    const at = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] ?? 0;
    const enters = (w.benchEnters as number[]).sort((a, b) => a - b);
    return {
      rows: rows.length,
      reached: seen.length,
      p50: at(0.5),
      p95: at(0.95),
      max: sorted.at(-1) ?? 0,
      enterP95: enters.length ? enters[Math.min(enters.length - 1, Math.floor(0.95 * enters.length))]! : 0,
      enterMax: enters.at(-1) ?? 0,
      slowEnters: enters.length,
      enters: w.benchEnterCount as number,
    };
  })) as Latency;
  await page.evaluate(() => {
    (window as any).benchFrames = false;
    console.timeStamp("bench-end");
  });
  return latency;
}

type Node = { id: number; callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number }; children?: number[] }; // prettier-ignore
function selfTimes(profile: { nodes: Node[]; samples: number[]; timeDeltas: number[] }) {
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const self = new Map<number, number>();
  profile.samples.forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000));
  const out = new Map<string, number>();
  for (const [id, ms] of self) {
    const f = byId.get(id)!.callFrame;
    const file = f.url ? path.basename(f.url.split("?")[0]!) : "";
    const key = `${f.functionName || "(anonymous)"} ${file}${file ? `:${f.lineNumber + 1}` : ""}`;
    out.set(key, (out.get(key) ?? 0) + ms);
  }
  return out;
}

const results: Record<string, { trace: ReturnType<typeof analyze>; latency: Latency }[]> = {};
const profiles: Record<string, Map<string, number>> = {};
const releases: Array<[string, () => unknown]> = [];
let prodDir = "";
try {
  const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "rail-hover-bench-"));
  releases.push(["traces", () => (KEEP_TRACES ? log(`traces kept in ${tmp}`) : fs.rmSync(tmp, { recursive: true, force: true }))]); // prettier-ignore
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string };
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);
  prodDir = await buildPane();
  if (!PROD_DIR) releases.push(["pane build", () => fs.rmSync(prodDir, { recursive: true, force: true })]);
  const statics = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(prodDir, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
    },
  });
  releases.push(["static server", () => statics.stop(true)]);
  url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({
    ...(process.env.CMUX_CHROME_HEADLESS_SHELL
      ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
      : { channel: "chrome" }),
    headless: true,
  });
  releases.push(["browser", () => browser.close()]);
  await (await open(browser, "plain")).close();
  for (let round = 0; round < ROUNDS; round++) {
    for (const arm of round % 2 ? [...ARMS].reverse() : ARMS) {
      const page = await open(browser, arm);
      const file = path.join(tmp, `${arm}-${round}.json`);
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
      const latency = await sweep(page);
      if (cdp) {
        const { profile } = await cdp.send("Profiler.stop");
        const out = path.join(tmp, `${arm}-${round}.cpuprofile`);
        fs.writeFileSync(out, JSON.stringify(profile));
        const times = selfTimes(profile as never);
        const into = (profiles[arm] ??= new Map());
        for (const [key, ms] of times) into.set(key, (into.get(key) ?? 0) + ms / ROUNDS);
        if (OUT && round === ROUNDS - 1) fs.copyFileSync(out, path.join(OUT, path.basename(out)));
      }
      await browser.stopTracing();
      if (OUT && round === ROUNDS - 1) fs.copyFileSync(file, path.join(OUT, path.basename(file)));
      (results[arm] ??= []).push({ trace: analyze(file), latency });
      await page.close();
    }
  }
} finally {
  for (const [name, release] of releases.reverse()) {
    try {
      await release();
    } catch (error) {
      log(`could not release the ${name}:`, error);
    }
  }
}

const median = (v: number[]) => pct(v, 50);
const fmt = (n: number) => n.toFixed(2).padStart(7);
console.log(
  `turns=${TURNS} rounds=${ROUNDS} seconds=${SECONDS} sweep ${STEP_PX}px/${STEP_MS}ms minify=${MINIFY} (medians of rounds)`,
);
console.log(
  "arm         busy p50 busy p95 busy max scr p95 rnd p95 frame p95 frames >16ms long | forced(n/ms) layout ms style ms paint ms styleEls p95/max",
);
for (const [arm, runs] of Object.entries(results)) {
  const m = (pick: (r: ReturnType<typeof analyze>) => number) => median(runs.map((r) => pick(r.trace)));
  console.log(
    `${arm.padEnd(11)} ${fmt(m((r) => r.p50))} ${fmt(m((r) => r.p95))} ${fmt(m((r) => r.max))} ${fmt(m((r) => r.scriptP95))} ${fmt(m((r) => r.renderP95))} ${fmt(m((r) => r.frameP95))} ${String(m((r) => r.frames)).padStart(6)} ${String(m((r) => r.over16)).padStart(5)} ${runs.map((r) => r.trace.longTasks).join(",")} | ${m((r) => r.forcedCount)}/${m((r) => r.forcedMs).toFixed(1)} ${fmt(m((r) => r.layoutMs))} ${fmt(m((r) => r.styleMs))} ${fmt(m((r) => r.paintMs))} ${m((r) => r.styleElementsP95)}/${m((r) => r.styleElementsMax)}`,
  );
}
console.log("row latency (pointermove into a row -> first frame showing it active with its card), ms:");
for (const [arm, runs] of Object.entries(results)) {
  const m = (pick: (r: Latency) => number) => median(runs.map((r) => pick(r.latency)));
  console.log(
    `${arm.padEnd(11)} rows ${m((r) => r.rows)} reached ${m((r) => r.reached)} p50 ${fmt(m((r) => r.p50))} p95 ${fmt(m((r) => r.p95))} max ${fmt(m((r) => r.max))} | pointerover ${m((r) => r.enters)}, event timing >=16ms: ${m((r) => r.slowEnters)} p95 ${fmt(m((r) => r.enterP95))} max ${fmt(m((r) => r.enterMax))}`,
  );
}
for (const [arm, times] of Object.entries(profiles)) {
  const total = sum([...times.values()]);
  console.log(`top self time, ${arm} (mean ms per ${SECONDS}s sweep; total sampled ${total.toFixed(0)} ms):`);
  for (const [key, ms] of [...times].sort((a, b) => b[1] - a[1]).slice(0, 30))
    console.log(`  ${ms.toFixed(1).padStart(7)}  ${key}`);
}
