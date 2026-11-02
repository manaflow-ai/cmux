// l10n-allow-file: benchmark fixture and diagnostic output, not shipped UI.
// Chromium, production React, the real pane and papercutChat's 1,200-turn log.
// bun bench/thread-rail-jump.bench.ts [turns=1200] [samples=20]
// RAIL_BENCH_OUT stores screenshots/JSON; PROD_DIR reuses this entry's production build.
// Paint samplers stop on success or a 10-second deadline. Finally closes all resources.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { chromium, type Page, type CDPSession } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow, TARGET_MS } from "./perfRow";

const pct = (values: number[], p: number) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * p) - 1]!;
const distribution = (values: number[]) => ({ p50: pct(values, 0.5), p95: pct(values, 0.95) });
async function idle(page: Page) {
  await page.evaluate(
    () =>
      new Promise<void>((resolve, reject) => {
        const start = performance.now();
        let previous = -1;
        let stable = 0;
        window.cmuxAfterPaint(() => {
          const top = document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop;
          stable = top === previous ? stable + 1 : 0;
          previous = top;
          if (performance.now() - start > 10_000) {
            reject(new Error("Scroll did not settle"));
            return false;
          }
          if (stable < 5) return true;
          resolve();
          return false;
        });
      }),
  );
}
export type RailScenarioResult = {
  p50: number;
  p95: number;
  droppedFrames: number;
  styleMs: number;
  layoutMs: number;
  jsMs: number;
  samples?: unknown[];
};

type SchemaCase = {
  id: string;
  metric: "target_painted" | "frame_time";
  unit: "ms";
  samples: number;
  p50: number | null;
  p95: number | null;
  max: number | null;
  longTasks: { count: number | null; totalMs: number | null; maxMs: number | null };
  reactCommits: number | null;
  frames: { count: number | null; dropped: number | null };
  breakdown: {
    scriptMs: number | null;
    styleMs: number | null;
    layoutMs: number | null;
    paintMs: number | null;
  };
};

const nullLongTasks = () => ({ count: null, totalMs: null, maxMs: null });
const percentiles = (values: number[]) => ({
  samples: values.length,
  p50: values.length ? pct(values, 0.5) : null,
  p95: values.length ? pct(values, 0.95) : null,
  max: values.length ? Math.max(...values) : null,
});

async function withTrace<T>(cdp: CDPSession, directory: string, name: string, run: () => Promise<T>): Promise<T> {
  const events: unknown[] = [];
  const onData = (event: { value?: unknown[] }) => events.push(...(event.value ?? []));
  cdp.on("Tracing.dataCollected", onData);
  let completeResolve: (() => void) | undefined;
  const complete = new Promise<void>((resolve) => (completeResolve = resolve));
  let traceComplete = false;
  const onComplete = () => {
    traceComplete = true;
    completeResolve?.();
  };
  cdp.on("Tracing.tracingComplete", onComplete);
  let started = false;
  try {
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline,blink.user_timing,v8.execute",
      transferMode: "ReportEvents",
    });
    started = true;
    return await run();
  } finally {
    if (started) {
      try {
        await cdp.send("Tracing.end");
        let timeout: ReturnType<typeof setTimeout> | undefined;
        await Promise.race([complete, new Promise<void>((resolve) => (timeout = setTimeout(resolve, 10_000)))]);
        if (timeout) clearTimeout(timeout);
      } catch {
        // A failed trace must not hide the benchmark result or leave a listener behind.
      }
    }
    cdp.off("Tracing.dataCollected", onData);
    cdp.off("Tracing.tracingComplete", onComplete);
    if (started) {
      const trace = JSON.stringify({ complete: traceComplete, traceEvents: events });
      const tracePath = path.join(directory, `${name}.trace.json`);
      fs.writeFileSync(tracePath, trace);
      if (process.env.RAIL_BENCH_EXPORT === "1")
        console.log(`RAIL_BENCH_TRACE ${JSON.stringify({ name, gzipBase64: gzipSync(trace).toString("base64") })}`);
    }
  }
}

function pagedEvents(events: any[], params: Record<string, any>, attach = false) {
  const after = Number(params.afterSeq ?? 0);
  const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
  const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
  const limit = params.limit === undefined ? (attach ? 400 : Infinity) : Math.max(1, Number(params.limit));
  const maxBytes = params.maxBytes === undefined ? Infinity : Number(params.maxBytes);
  const kinds = Array.isArray(params.kinds) ? params.kinds : [];
  const wanted = (event: any) =>
    kinds.length === 0 ||
    kinds.includes(event.kind) ||
    (event.kind !== "available_commands_update" && kinds.includes("transcript"));
  const page: any[] = [];
  let bytes = 0;
  let hasMore = false;
  const take = (event: any) => {
    if (event.seq <= after || event.seq >= before || !wanted(event)) return true;
    if (page.length >= limit) return !(hasMore = true);
    bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
    if (page.length > 0 && bytes > maxBytes) return !(hasMore = true);
    page.push(event);
    return true;
  };
  if (newest) for (let index = events.length - 1; index >= 0 && take(events[index]!); index -= 1);
  else for (const event of events) if (!take(event)) break;
  if (newest) page.reverse();
  return { events: page, hasMore };
}

async function preloadPaged(page: Page, pages = 2): Promise<number> {
  const rail = page.locator(".acpmux-minimap__list");
  for (let count = 0; count < pages; count += 1) {
    const before = Number(await rail.locator("[aria-setsize]").first().getAttribute("aria-setsize"));
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!node) return;
      node.scrollTop = 0;
      node.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: -1 }));
    });
    await page.waitForFunction(
      (previous) => Number(document.querySelector("[aria-setsize]")?.getAttribute("aria-setsize") ?? 0) > previous,
      before,
      { timeout: 15_000 },
    );
  }
  return Number(await rail.locator("[aria-setsize]").first().getAttribute("aria-setsize"));
}

function schemaCase(
  id: string,
  metric: SchemaCase["metric"],
  result: RailScenarioResult,
  values: number[],
  frameCount: number | null,
  dropped: number | null,
): SchemaCase {
  return {
    id,
    metric,
    unit: "ms",
    ...percentiles(values),
    longTasks: nullLongTasks(),
    reactCommits: null,
    frames: { count: frameCount, dropped },
    breakdown: {
      scriptMs: result.jsMs ?? null,
      styleMs: result.styleMs ?? null,
      layoutMs: result.layoutMs ?? null,
      paintMs: null,
    },
  };
}

function renderer(cdp: CDPSession) {
  const metrics = async () =>
    Object.fromEntries((await cdp.send("Performance.getMetrics")).metrics.map(({ name, value }) => [name, value]));
  const costs = (before: Record<string, number>, after: Record<string, number>) => {
    const delta = (key: string) => ((after[key] ?? 0) - (before[key] ?? 0)) * 1000;
    return {
      TaskDurationMs: delta("TaskDuration"),
      LayoutDurationMs: delta("LayoutDuration"),
      RecalcStyleDurationMs: delta("RecalcStyleDuration"),
      ScriptDurationMs: delta("ScriptDuration"),
    };
  };
  return { metrics, costs };
}

export async function measureTickJumps(
  page: Page,
  cdp: CDPSession,
  turns: number,
  samples: number,
  frameMs: number,
): Promise<RailScenarioResult & { samples: unknown[] }> {
  const rail = page.locator(".acpmux-minimap__list");
  const { metrics, costs } = renderer(cdp);
  const jumps = [];
  for (let sample = 0; sample < samples; sample++) {
    const index = 20 + ((sample * 463) % (turns - 40));
    await rail.evaluate(async (node, index) => {
      node.scrollTop = index * 10 - node.clientHeight / 2;
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    }, index);
    const tick = rail.locator(`[data-tick="${index}"]`);
    await tick.waitFor();
    // The actual DOM click starts the sample; actionability and hover time are excluded.
    await page.evaluate(
      ({ index, frameMs }) => {
        const probe = window as unknown as { railJump: unknown };
        probe.railJump = null;
        const button = document.querySelector<HTMLElement>(`[data-tick="${index}"]`)!;
        const prompt = `Question ${button.getAttribute("aria-label")?.match(/Question (\d+)/)?.[1] ?? index + 1}`;
        button.addEventListener(
          "click",
          () => {
            const start = performance.now();
            let previous: number | undefined;
            let frames = 0;
            let dropped = 0;
            let firstPaint: number | undefined;
            let stable = 0;
            let lastTop: number | undefined;
            window.cmuxAfterPaint((frame) => {
              frames++;
              if (previous !== undefined) dropped += Math.max(0, Math.round((frame - previous) / frameMs) - 1);
              previous = frame;
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const view = scroller.getBoundingClientRect();
              const bubble = [...scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")].find(
                (node) => node.textContent?.trim() === prompt,
              );
              const box = bubble?.getBoundingClientRect();
              const visible =
                box &&
                box.width > 0 &&
                box.height > 0 &&
                box.bottom > view.top &&
                box.top < view.bottom &&
                box.right > view.left &&
                box.left < view.right &&
                box.bottom > 0 &&
                box.top < window.innerHeight &&
                box.right > 0 &&
                box.left < window.innerWidth;
              const elapsed = performance.now() - start;
              if (visible && firstPaint === undefined) firstPaint = elapsed;
              stable = visible && lastTop !== undefined && Math.abs(box.top - lastTop) < 0.5 ? stable + 1 : 0;
              lastTop = visible ? box.top : undefined;
              if (stable >= 3 || elapsed > 10_000) {
                probe.railJump = {
                  index,
                  firstPaintMs: firstPaint,
                  settledMs: elapsed,
                  frames,
                  dropped,
                  timeout: stable < 3,
                };
                return false;
              }
              return true;
            });
          },
          { capture: true, once: true },
        );
      },
      { index, frameMs },
    );
    const before = await metrics();
    await tick.click();
    await page.waitForFunction(() => (window as unknown as { railJump: unknown }).railJump, {}, { timeout: 15_000 });
    const result = await page.evaluate(
      () =>
        (
          window as unknown as {
            railJump: { firstPaintMs: number; timeout: boolean; dropped: number };
          }
        ).railJump,
    );
    if (result.timeout || result.firstPaintMs === undefined) throw new Error(`Jump failed: ${JSON.stringify(result)}`);
    jumps.push({ ...result, ...costs(before, await metrics()) });
    await page.mouse.move(1000, 50);
    await idle(page);
  }
  return {
    ...distribution(jumps.map((j) => j.firstPaintMs)),
    droppedFrames: jumps.reduce((sum, j) => sum + j.dropped, 0),
    styleMs: jumps.reduce((sum, j) => sum + (j.RecalcStyleDurationMs ?? 0), 0),
    layoutMs: jumps.reduce((sum, j) => sum + (j.LayoutDurationMs ?? 0), 0),
    jsMs: jumps.reduce((sum, j) => sum + (j.ScriptDurationMs ?? 0), 0),
    samples: jumps,
  };
}

export async function measureRailReveal(
  page: Page,
  cdp: CDPSession,
  turns: number,
  samples: number,
  frameMs: number,
): Promise<RailScenarioResult & { frames: { p50: number; p95: number } }> {
  const rail = page.locator(".acpmux-minimap__list");
  const { metrics, costs } = renderer(cdp);
  const before = await metrics();
  // A tick existing in the DOM is not necessarily painted: its entrance can hold it at
  // opacity/scale zero. Measure a distant rail scroll through its final resting appearance.
  const railDraws = [];
  for (let sample = 0; sample < samples; sample++) {
    const index = 40 + ((sample * 463) % (turns - 80));
    railDraws.push(
      await rail.evaluate(
        (node, { index, frameMs }) =>
          new Promise<{ ms: number; frames: number; dropped: number }>((resolve, reject) => {
            const start = performance.now();
            let frames = 0;
            let previous: number | undefined;
            let dropped = 0;
            node.scrollTop = index * 10 - node.clientHeight / 2;
            window.cmuxAfterPaint((frame) => {
              frames++;
              if (previous !== undefined) dropped += Math.max(0, Math.round((frame - previous) / frameMs) - 1);
              previous = frame;
              const bar = node.querySelector<HTMLElement>(`[data-tick="${index}"] .acpmux-minimap__bar`);
              const entering = bar
                ?.getAnimations()
                .some(
                  (animation) =>
                    (animation as CSSAnimation).animationName === "acpmux-minimap-tick-in" &&
                    animation.playState !== "finished",
                );
              const ms = performance.now() - start;
              if (ms > 10_000) {
                reject(new Error("Rail tick never painted"));
                return false;
              }
              if (!bar || entering || Number(getComputedStyle(bar).opacity) < 0.39) return true;
              resolve({ ms, frames, dropped });
              return false;
            });
          }),
        { index, frameMs },
      ),
    );
  }
  const cost = costs(before, await metrics());
  return {
    ...distribution(railDraws.map((d) => d.ms)),
    droppedFrames: railDraws.reduce((sum, d) => sum + d.dropped, 0),
    styleMs: cost.RecalcStyleDurationMs!,
    layoutMs: cost.LayoutDurationMs!,
    jsMs: cost.ScriptDurationMs!,
    frames: distribution(railDraws.map((d) => d.frames)),
    samples: railDraws,
  };
}

export async function measureRailScroll(
  page: Page,
  cdp: CDPSession,
  frameMs: number,
): Promise<RailScenarioResult & { frames: number; elapsedMs: number; taskMsPerFrame: number; gaps: number }> {
  const rail = page.locator(".acpmux-minimap__list");
  const { metrics, costs } = renderer(cdp);
  // Rail-only scroll work, separately from vsync wall time. Check each exposed center tick.
  const before = await metrics();
  const scroll = await rail.evaluate(
    (node) =>
      new Promise<{ elapsedMs: number; frames: number; gaps: number; intervals: number[] }>((resolve, reject) => {
        const start = performance.now();
        const intervals: number[] = [];
        let previous: number | undefined;
        let frames = 0;
        let gaps = 0;
        window.cmuxAfterPaint(
          (frame) => {
            if (previous !== undefined) intervals.push(frame - previous);
            previous = frame;
            frames++;
            const index = Math.floor((node.scrollTop + node.clientHeight / 2) / 10);
            if (!node.querySelector(`[data-tick="${index}"]`)) gaps++;
            if (performance.now() - start > 10_000) {
              reject(new Error("Rail scroll timeout"));
              return false;
            }
            if (frames < 120) return true;
            resolve({ elapsedMs: performance.now() - start, frames, gaps, intervals });
            return false;
          },
          () => {
            node.scrollTop = ((node.scrollHeight - node.clientHeight) * (frames % 60)) / 59;
          },
        );
      }),
  );
  const scrollCosts = costs(before, await metrics());
  return {
    ...distribution(scroll.intervals),
    droppedFrames: scroll.intervals.reduce((sum, ms) => sum + Math.max(0, Math.round(ms / frameMs) - 1), 0),
    styleMs: scrollCosts.RecalcStyleDurationMs!,
    layoutMs: scrollCosts.LayoutDurationMs!,
    jsMs: scrollCosts.ScriptDurationMs!,
    frames: scroll.frames,
    elapsedMs: scroll.elapsedMs,
    gaps: scroll.gaps,
    taskMsPerFrame: scrollCosts.TaskDurationMs! / scroll.frames,
    samples: scroll.intervals,
  };
}

async function main() {
  const turns = Number(process.argv[2] ?? 1200);
  const samples = Number(process.argv[3] ?? 20);
  if (turns < 1000 || samples < 5) throw new Error("Use at least 1,000 turns and five samples");
  const out = process.env.RAIL_BENCH_OUT;
  if (out) fs.mkdirSync(out, { recursive: true });
  const traceOut = out ?? fs.mkdtempSync(path.join(os.tmpdir(), "rail-traces-"));
  const temporary = !process.env.PROD_DIR;
  const prod = process.env.PROD_DIR ?? fs.mkdtempSync(path.join(os.tmpdir(), "rail-jump-"));
  const { events, session } = papercutEvents({ turns, running: false });
  const paged = process.env.RAIL_BENCH_PAGED === "1";
  const methods: string[] = [];
  const answer = (method: string, params: Record<string, any> = {}) => {
    methods.push(method);
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return {
          session,
          lastSeq: events.length,
          ...(paged ? pagedEvents(events, params, true) : { events, hasMore: false }),
        };
      case "_acpmux/events":
        return paged
          ? { ...pagedEvents(events, params), lastSeq: events.length }
          : { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: (request, server) => (server.upgrade(request) ? undefined : new Response("WebSocket", { status: 426 })),
    websocket: {
      message(ws, raw) {
        const msg = JSON.parse(String(raw));
        if (msg.id !== undefined)
          ws.send(
            JSON.stringify({
              jsonrpc: "2.0",
              id: msg.id,
              result: answer(msg.method, msg.params ?? {}),
            }),
          );
      },
    },
  });
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      const pathname = new URL(request.url).pathname;
      const file = Bun.file(path.join(prod, pathname === "/" ? "index.html" : pathname));
      return (await file.exists()) ? new Response(file) : new Response("Not found", { status: 404 });
    },
  });
  const browser = await chromium.launch({ headless: true });
  try {
    if (temporary) {
      const { build } = await import("vite");
      await build({
        configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
        build: { outDir: prod, emptyOutDir: true },
        logLevel: "error",
      });
    }
    const arms: Record<string, string> = {
      base: "",
      "fixed-stagger":
        ".acpmux-minimap__list { --acpmux-minimap-first: 0 !important; --acpmux-minimap-rows: 1 !important; }",
      "no-entrance": ".acpmux-minimap__bar, .acpmux-minimap__dot { animation: none !important; }",
    };
    for (const arm of (process.env.RAIL_BENCH_ARMS ?? "base").split(",")) {
      if (!(arm in arms)) throw new Error(`Unknown benchmark arm ${arm}`);
      const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
      page.on("pageerror", (error) => console.error(error));
      await installPaintedFrames(page);
      const url = `http://127.0.0.1:${server.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
      await page.goto(url);
      await page.getByText(`Answer ${turns}:`, { exact: false }).waitFor({ timeout: 120_000 });
      await idle(page);
      if (arms[arm]) await page.addStyleTag({ content: arms[arm]! });
      const rail = page.locator(".acpmux-minimap__list");
      await rail.waitFor();
      let count = Number(await rail.locator("[aria-setsize]").first().getAttribute("aria-setsize"));
      if (paged) {
        count = await preloadPaged(page);
        await idle(page);
      }
      if (!paged && count !== turns) throw new Error(`Expected ${turns} ticks, got ${count}`);
      const cadence = await page.evaluate(
        () =>
          new Promise<number[]>((resolve) => {
            const frames: number[] = [];
            window.cmuxAfterPaint((frame) => {
              frames.push(frame);
              if (frames.length < 31) return true;
              resolve(frames.slice(1).map((t, i) => t - frames[i]!));
              return false;
            });
          }),
      );
      const frameMs = pct(cadence, 0.5);
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Performance.enable");
      console.log(`RAIL_BENCH_START ${arm}${paged ? "-paged" : ""} turns=${turns} samples=${samples}`);
      const report = await withTrace(cdp, traceOut, `${arm}${paged ? "-paged" : ""}`, async () => {
        const jump = await measureTickJumps(page, cdp, paged ? count : turns, samples, frameMs);
        const railReveal = await measureRailReveal(page, cdp, paged ? count : turns, samples, frameMs);
        const railScroll = await measureRailScroll(page, cdp, frameMs);
        const cases: SchemaCase[] = [
          schemaCase(
            `thread-rail.tick-click.${paged ? "loaded-after-paging" : "loaded"}-${turns}`,
            "target_painted",
            jump,
            jump.samples.map((sample: any) => sample.firstPaintMs),
            jump.samples.reduce((sum: number, sample: any) => sum + sample.frames, 0),
            jump.samples.reduce((sum: number, sample: any) => sum + sample.dropped, 0),
          ),
          schemaCase(
            `thread-rail.tick-reveal.${paged ? "loaded-after-paging" : "loaded"}-${turns}`,
            "target_painted",
            railReveal,
            railReveal.samples!.map((sample: any) => sample.ms),
            railReveal.samples!.reduce((sum: number, sample: any) => sum + sample.frames, 0),
            railReveal.samples!.reduce((sum: number, sample: any) => sum + sample.dropped, 0),
          ),
          schemaCase(
            `thread-rail.scroll.${paged ? "loaded-after-paging" : "loaded"}-${turns}`,
            "frame_time",
            railScroll,
            railScroll.samples as number[],
            railScroll.frames,
            railScroll.droppedFrames,
          ),
        ];
        const schema = {
          schemaVersion: 1,
          source: {
            repo: process.env.RAIL_BENCH_REPO ?? "manaflow-ai/cmux",
            head: process.env.RAIL_BENCH_HEAD ?? Bun.spawnSync(["git", "rev-parse", "HEAD"]).stdout.toString().trim(),
            base: process.env.RAIL_BENCH_BASE ?? null,
            browser: browser.version(),
            viewport: { width: 1280, height: 900 },
            runner: process.env.RAIL_BENCH_RUNNER ?? process.env.RUNNER_NAME ?? null,
          },
          cases,
          idle: {
            sampleMs: null,
            cpuMs: null,
            cpuPercent: null,
            wakeups: null,
            wakeupSource: null,
          },
          notes: [
            "Long-task, React-commit, paint, and idle counters were not collected; frame drops are cadence estimates.",
            ...(paged
              ? [
                  "loaded-after-paging clicks already loaded targets after two loadOlder pages; unloaded-target click is unsupported until index/loadThrough lands.",
                ]
              : []),
          ],
          paging: paged
            ? {
                loadedTicks: count,
                eventRequests: methods.filter((method) => method === "_acpmux/events").length,
                unloadedTarget: "unsupported",
              }
            : null,
          rawSamples: `${arm}${paged ? "-paged" : ""}-raw-samples.json`,
        };
        const raw = { turns, samples, frameMs, arm, paged, jump, railReveal, railScroll };
        if (out) {
          fs.writeFileSync(path.join(out, schema.rawSamples), JSON.stringify(raw, null, 2));
          fs.writeFileSync(
            path.join(out, `${arm}${paged ? "-paged" : ""}-schema-v1.json`),
            JSON.stringify(schema, null, 2),
          );
        }
        return {
          arm,
          turns,
          samples,
          frameMs,
          browser: browser.version(),
          paged,
          jump,
          railReveal,
          railScroll,
          schema,
        };
      });
      if (out) await page.screenshot({ path: path.join(out, `${arm}-jump.png`) });
      console.log("RAIL_BENCH " + JSON.stringify(report));
      // thread-rail.tick-click.loaded-1000 -> thread_rail.tick_click.loaded_1000.<arm>: a tick click or reveal
      // until the target paints (a response). A rail scroll's frame time is the painted-frame interval, which a
      // headless runner's frame clock sets (16.7 ms), not work: a row with no target, so a dropped frame still shows.
      for (const each of report.schema.cases)
        if (each.p95 !== null)
          perfRow({
            name: `${each.id.replaceAll("-", "_")}.${arm.replaceAll("-", "_")}`,
            p50: each.p50 ?? undefined,
            p95: each.p95,
            target: each.metric === "frame_time" ? undefined : TARGET_MS.response,
          });
      if (out) fs.writeFileSync(path.join(out, `${arm}-results.json`), JSON.stringify(report, null, 2));
      await page.close();
    }
  } finally {
    await browser.close();
    await daemon.stop(true);
    await server.stop(true);
    if (temporary) fs.rmSync(prod, { recursive: true, force: true });
  }
}

if (import.meta.main) await main();
