// l10n-allow-file: bench output labels, not shipped UI.
// Does the chat pane survive a divider drag beside a 100k-row chat while a reply streams, and what
// does the frame cost?
//
// #44389 measured that case and reported: "The 100k-row streaming case drops every frame (84-89 ms
// each) and then the bench page crashes, on base and on head alike." It also said why that number
// is not the app's: the harness shaped the whole chat again on every chunk (`turnView`, which
// starts from nothing), while the pane builds each update on the one before it (App.tsx
// `shapeFrom`, which passes `last?.turns` to `turnViewFrom`). So the crash it saw may belong to the
// harness and not to the app, and it said the way to tell is to shape rows as the app does and
// measure again.
//
// This bench is that measurement. It runs the same drag twice at the same length, changing only how
// the harness shapes rows (`window.__shaping`, test/browser/transcript-fling.harness.tsx):
//   - `scratch`: the whole chat reshaped per chunk, what every caller measured before;
//   - `app`: `turnViewFrom` given the view drawn last, what the pane itself does.
// A crash is the result, not an error: each run reports whether the page died, at which frame, and
// what it cost up to then, so "the app crashes" and "the harness crashed" are told apart by a
// number instead of by reading code.
//
//   bun bench/transcript-resize-stream-shaping.bench.ts [rows=100000] [modes=scratch,app]
//
// `__debug.seedRows(n)` seeds n rows, not n turns (a 200 run reports 198 rows), so the length
// #44389 reported the crash at is 100,000 here.
/// <reference types="bun" />
import { chromium } from "./browsers";
import { buildLabel, devRequested, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";

const ROWS = Number(process.argv[2] ?? 100_000);
/// A mode is how rows are shaped, with `-nomap` to draw the transcript without the thread minimap:
/// `app` and `app-nomap` together say how much of a frame is the rail's.
const MODES = (process.argv[3] ?? "scratch,app").split(",").map((name) => {
  const minimap = !name.endsWith("-nomap");
  const shaping = minimap ? name : name.slice(0, -"-nomap".length);
  if (shaping !== "scratch" && shaping !== "app")
    throw new Error("usage: [rows>=3] [modes=scratch|app|scratch-nomap|app-nomap,...]");
  return { name, shaping: shaping as "scratch" | "app", minimap };
});
if (!Number.isInteger(ROWS) || ROWS < 3) throw new Error("usage: [rows>=3] [modes=scratch,app]");

/// The drag: WIDE to NARROW and back, one width a frame, as a divider under the pointer gives.
const WIDE = 900;
const NARROW = 520;
const STEPS = 90;

type Run = {
  mode: string;
  /// The page died during the drag: Chromium lost the renderer (an out-of-memory kill shows here).
  crashed: boolean;
  /// The frame it died on, of STEPS * 2 (null: it lived).
  crashedAtFrame: number | null;
  /// Frames whose work was recorded before it died.
  frames: number;
  work: { p50: number; p95: number; max: number };
  /// The chunks the streaming reply got through.
  chunks: number;
  /// What the shaping reused per update (`TurnView.reusedRows`): app shaping keeps nearly every row.
  reusedMin: number | null;
  reusedMedian: number | null;
  sourceRows: number;
  /// The renderer's JS heap after the drag, MB (Chromium only; null when the page died).
  heapMb: number | null;
  /// p95 of the pane's own render and layout spans over the drag, ms, and its costliest spans.
  reactMs: number;
  layoutMs: number;
  spans: Record<string, number>;
};

const pct = (values: number[], p: number) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return Math.round((sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0) * 100) / 100;
};

const pagePath = "/test/browser/transcript-fling.html";
/// A build by default; `--dev` takes a dev server instead and labels every number `dev`
/// (bench/support/benchPage.ts): React's development bundle was about a third of a frame here.
const DEV = devRequested();
const served = await serveBenchPage(pagePath, { dev: DEV });
// --expose-gc so a run can settle its garbage before the heap is read, and a large old space so the
// renderer's own limit, not the bench host's, is what a run meets.
const browser = await chromium.launch({
  headless: true,
  args: ["--js-flags=--expose-gc"],
});
const runs: Run[] = [];
try {
  console.log(`resize-stream-shaping build=${buildLabel({ dev: DEV })}`);
  for (const mode of MODES) {
    const page = await browser.newPage({ viewport: { width: WIDE + 100, height: 900 } });
    let crashed = false;
    page.on("crash", () => (crashed = true));
    await gotoBenchPage(page, served);
    await requireProductionReact(page, { dev: DEV });
    // `__debug` is installed right after `createRoot().render()`, but `__shaping` is installed by
    // the harness's first render, which a concurrent root does not run synchronously. So wait for
    // the shaping switch itself, not for `__debug`.
    await page.waitForFunction(() => "__shaping" in window && "__debug" in window);
    await page.evaluate(
      (how: { shaping: string; minimap: boolean }) => {
        const api = window as unknown as { __shaping: (m: string) => void; __minimap: (on: boolean) => void };
        api.__shaping(how.shaping);
        api.__minimap(how.minimap);
      },
      { shaping: mode.shaping, minimap: mode.minimap },
    );
    const seeded = await page.evaluate(`window.__debug.seedRows(${ROWS})`);
    console.log(`resize-stream-shaping mode=${mode.name} rows=${ROWS} fixture=${JSON.stringify(seeded)}`);

    // The drag, one width a frame, a streamed chunk on each: the page reports what it got through,
    // so a crash mid-drag still leaves the frames before it readable.
    const drag = await page
      .evaluate(
        async ({ wide, narrow, steps }) => {
          const perfUrl = "/src/agent-session/acpmux/perf.ts";
          type PerfModule = typeof import("../src/agent-session/acpmux/perf");
          const { acpmuxPerf } = (await import(/* @vite-ignore */ perfUrl)) as PerfModule;
          const root = document.getElementById("root")!;
          root.style.width = `${wide}px`;
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
          // Following the latest row, where a streaming reply is read.
          scroller.scrollTop = scroller.scrollHeight;
          for (let frame = 0; frame < 30; frame += 1) await new Promise(requestAnimationFrame);
          acpmuxPerf.enable();
          acpmuxPerf.resetFrames();
          const widths = [
            ...Array.from({ length: steps }, (_, i) => wide - ((wide - narrow) * (i + 1)) / steps),
            ...Array.from({ length: steps }, (_, i) => narrow + ((wide - narrow) * (i + 1)) / steps),
          ].map(Math.round);
          const step = window as unknown as { __stepFoldStream: () => void };
          const work: number[] = [];
          let chunks = 0;
          // One width a frame, with a streamed chunk on each: what a person has on screen when an
          // agent answers and they drag the divider. `markFrame` delimits the frames the pane's own
          // spans are attributed to (without it `stats()` reports nothing), and the task posted on a
          // MessageChannel runs once the frame's rendering step finished, so `work` is the frame's
          // whole main-thread cost, layout and paint included. Same shape as
          // transcript-resize-frame.bench.ts, so the two read the same thing.
          await new Promise<void>((done) => {
            let index = 0;
            const tick = (now: number) => {
              acpmuxPerf.markFrame(now, false);
              if (index >= widths.length) return done();
              const started = performance.now();
              root.style.width = `${widths[index]}px`;
              index += 1;
              step.__stepFoldStream();
              chunks += 1;
              const channel = new MessageChannel();
              channel.port1.onmessage = () => work.push(performance.now() - started);
              channel.port2.postMessage(0);
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          });
          // Let the last frame's task land, then the width hold settle, before the spans are read.
          await new Promise((resolve) => setTimeout(resolve, 50));
          // Where the frame went, from the pane's own spans: a frame still over budget with the
          // rows reused says the cost is not the shaping, and these name what it is instead.
          const perfStats = acpmuxPerf.stats() as unknown as {
            react?: { p95_ms: number };
            layout?: { p95_ms: number };
            spans?: Record<string, { p95_ms: number }>;
          };
          const stats = (
            window as unknown as { __shapingStats: () => { updates: number; reused: number[]; source: number } }
          ).__shapingStats();
          const gc = (globalThis as unknown as { gc?: () => void }).gc;
          gc?.();
          const heap = (performance as unknown as { memory?: { usedJSHeapSize: number } }).memory;
          return {
            work,
            chunks,
            reused: stats.reused,
            sourceRows: stats.source,
            reactMs: perfStats.react?.p95_ms ?? 0,
            layoutMs: perfStats.layout?.p95_ms ?? 0,
            spans: Object.fromEntries(
              Object.entries(perfStats.spans ?? {})
                .map(([k, v]) => [k, v.p95_ms] as const)
                .sort((a, b) => b[1] - a[1])
                .slice(0, 12),
            ),
            heapMb: heap ? Math.round(heap.usedJSHeapSize / 1e5) / 10 : null,
          };
        },
        { wide: WIDE, narrow: NARROW, steps: STEPS },
      )
      .catch((error: Error) => {
        // "Target crashed" / "Target closed": the renderer died mid-drag. That is this bench's
        // result, so it is reported, never thrown.
        if (/crash|Target closed|detached/i.test(error.message)) return null;
        throw error;
      });

    if (!drag) {
      console.log(`resize-stream-shaping mode=${mode.name} CRASHED during the drag`);
      runs.push({
        mode: mode.name,
        crashed: true,
        crashedAtFrame: null,
        frames: 0,
        work: { p50: 0, p95: 0, max: 0 },
        chunks: 0,
        reusedMin: null,
        reusedMedian: null,
        sourceRows: 0,
        heapMb: null,
        reactMs: 0,
        layoutMs: 0,
        spans: {},
      });
    } else {
      const reused = [...drag.reused].sort((a, b) => a - b);
      runs.push({
        mode: mode.name,
        crashed,
        crashedAtFrame: null,
        frames: drag.work.length,
        work: { p50: pct(drag.work, 0.5), p95: pct(drag.work, 0.95), max: pct(drag.work, 1) },
        chunks: drag.chunks,
        reusedMin: reused[0] ?? null,
        reusedMedian: reused[Math.floor(reused.length / 2)] ?? null,
        sourceRows: drag.sourceRows,
        heapMb: drag.heapMb,
        reactMs: drag.reactMs,
        layoutMs: drag.layoutMs,
        spans: drag.spans as Record<string, number>,
      });
    }
    await page.close().catch(() => {});
  }
} finally {
  await browser.close();
  await served.close();
}

console.log("");
console.log(
  `| shaping | crashed | frames | frame work p50 / p95 / max ms | chunks | rows reused per update (min / median) | heap MB |`,
);
console.log(`|---|---|---|---|---|---|---|`);
for (const run of runs)
  console.log(
    `| ${run.mode} | ${run.crashed ? "YES" : "no"} | ${run.frames} | ${run.work.p50} / ${run.work.p95} / ${run.work.max} | ${run.chunks} | ${run.reusedMin ?? "-"} / ${run.reusedMedian ?? "-"} (of ${run.sourceRows}) | ${run.heapMb ?? "-"} |`,
  );
for (const run of runs)
  console.log(
    `resize-stream-shaping ${run.mode}: react_p95=${run.reactMs} layout_p95=${run.layoutMs} spans_p95=${JSON.stringify(run.spans)}`,
  );
console.log("");
console.log(JSON.stringify({ rows: ROWS, runs }));
