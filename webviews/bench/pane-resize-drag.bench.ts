// l10n-allow-file: bench output labels, not shipped UI.
// Frame time while the split divider beside an agent chat is dragged the way a person drags it:
// wide, narrow, a jiggle at narrow, wide again, over about 3.3 s, with 150-300 ms pauses between the
// moves, beside a long chat (bench/pane-resize-drag/longChat.ts: prompts, tool rows, diffs, and
// Markdown replies with headings, lists, code and tables), at 200, 700 and 2000 turns.
//
// Why another drag bench: transcript-resize-frame.bench.ts steps the width once a frame with no
// pause and synthetic one-paragraph replies, and the transcript drag tests count renders, not time.
// Leo's recording (2026-11-18) was 12-16 fps, 0-4 fps with the chat narrow, and single frames of
// 0.9-1.5 s, beside a 700-turn chat, with pauses in the drag. The transcript ends a live resize
// LIVE_RESIZE_MS (120 ms) after the last width (conversation/liveResizeStep.ts) and then measures
// the whole chat at the width that holds (VirtualTranscript `endFlow` / `settleResize`), and its
// rows flow again only from a drag's LIVE_FLOW_STEPS-th step, so every pause longer than 120 ms
// costs a whole-chat settle and the frames right after it run without the flow. This bench puts
// those pauses in the drag and reports the frames by phase:
//   drag    frames while the divider moves (the resume frames included)
//   resume  the first RESUME_FRAMES frames of a move that follows a pause
//   settle  frames while the width holds after a move (each pause, and the hold after the drag)
//   all     drag + settle (the pre-roll at rest before the first move is left out)
//
// Each frame is the interval between two requestAnimationFrame callbacks (what a person sees), and
// its `work`: from the width write in the frame's callback to a task posted from it, which runs once
// the frame's rendering step (style, layout, ResizeObservers and the React renders they run, paint)
// finished. Long animation frames (Chromium's long-animation-frame entries, with the scripts in them)
// and long tasks are recorded where the engine has them. One more drag per case runs with the pane's
// own measuring on (perf.ts acpmuxPerf: per-frame spans such as flush.drawn, row.measure, layout and
// React ms), reported apart, since measuring costs a little itself.
//
// Drivers (--driver): `root` (default) narrows the transcript's box in the page, as the transcript
// drag tests and transcript-resize-frame do, on the page's own frame clock; `viewport` resizes the
// whole page from Playwright (page.setViewportSize) on the runner's clock, as the app's divider
// resizes the chat's web view, media queries included.
//
// Output: one line per case (PANE_RESIZE_DRAG {...}, a readable line before it), a JSON file per case
// and summary.json in --out (default $FAST_CHECKS_OUT, else /tmp/pane-resize-drag), which
// scripts/bench/benches/pane_resize_drag.py reads (`cmux-bench pane-resize-drag --import summary.json`).
// Target (Leo's stop condition for the lane): p95 <= 18.2 ms (55 fps) and no frame over 50 ms in
// every phase at 700 turns. Printed, never enforced: no exit code follows from it.
//
//   bun bench/pane-resize-drag.bench.ts [--turns=200,700,2000] [--engines=chromium,webkit] [--rounds=3]
//     [--driver=root|viewport] [--wide=900] [--narrow=320] [--out=DIR] [--no-spans] [--profile] [--dev]
// On a lane VM (runs on a Linux CI box, never here):
//   cmux-ci test --setup playwright --artifact /tmp/dragbench -- bash bench/pane-resize-drag/ci.sh
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, BrowserType, Page } from "playwright";
import { chromium, webkit } from "./browsers";
import { buildLabel, devRequested, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { perfRow } from "./perfRow";

// ---- arguments ---------------------------------------------------------------------------------

const flag = (name: string): string | undefined => {
  const hit = process.argv.slice(2).find((arg) => arg === `--${name}` || arg.startsWith(`--${name}=`));
  if (hit === undefined) return undefined;
  return hit.includes("=") ? hit.slice(hit.indexOf("=") + 1) : "";
};
const list = (value: string | undefined, fallback: string) => (value || fallback).split(",").filter(Boolean);

const TURNS = list(flag("turns"), "200,700,2000").map(Number);
const ENGINES = list(flag("engines"), "chromium,webkit");
const ROUNDS = Number(flag("rounds") ?? 3);
const DRIVER = (flag("driver") || "root") as "root" | "viewport";
const WIDE = Number(flag("wide") ?? 900);
const NARROW = Number(flag("narrow") ?? 320);
const SPANS = flag("no-spans") === undefined;
const PROFILE = flag("profile") !== undefined;
const DEV = devRequested();
const OUT = flag("out") || process.env.FAST_CHECKS_OUT || "/tmp/pane-resize-drag";
const HEIGHT = 900;
if (
  TURNS.some((turns) => !Number.isInteger(turns) || turns < 1) ||
  !Number.isInteger(ROUNDS) ||
  ROUNDS < 1 ||
  !["root", "viewport"].includes(DRIVER) ||
  ENGINES.some((engine) => engine !== "chromium" && engine !== "webkit") ||
  !(NARROW > 0 && WIDE > NARROW)
)
  throw new Error(
    "usage: pane-resize-drag.bench.ts [--turns=N,...] [--engines=chromium,webkit] [--rounds=N] [--driver=root|viewport] [--wide=PX] [--narrow=PX] [--out=DIR] [--no-spans] [--profile] [--dev]",
  );

// ---- the drag ----------------------------------------------------------------------------------

/// The 60 fps frame budget at the lane's stop target (p95 at 55 fps).
const TARGET_P95_MS = 1000 / 55;
const TARGET_MAX_MS = 50;
/// The frames of a move after a pause reported as `resume` (the flow needs LIVE_FLOW_STEPS widths).
const RESUME_FRAMES = 3;

type Seg = { kind: "hold" | "move"; ms: number; to: number };
/// A person's drag: moves at different speeds, pauses of 150-300 ms, a jiggle with the chat narrow.
const mid = Math.round(WIDE - (WIDE - NARROW) * 0.48);
const SCRIPT: Seg[] = [
  { kind: "hold", ms: 300, to: WIDE }, // pre-roll at rest (not reported)
  { kind: "move", ms: 500, to: mid }, // quick move in
  { kind: "hold", ms: 200, to: mid },
  { kind: "move", ms: 700, to: NARROW }, // slow move to narrow
  { kind: "hold", ms: 300, to: NARROW },
  { kind: "move", ms: 400, to: NARROW + 60 }, // jiggle at narrow
  { kind: "move", ms: 250, to: NARROW + 10 },
  { kind: "hold", ms: 150, to: NARROW + 10 },
  { kind: "move", ms: 800, to: WIDE }, // back out
  { kind: "hold", ms: 700, to: WIDE }, // the settle after the drag
];
/// The script with each segment's start, end and starting width, in ms from the drag's first frame.
type PlacedSeg = Seg & { index: number; start: number; end: number; from: number; afterHold: boolean };
const PLACED: PlacedSeg[] = (() => {
  let start = 0;
  let from = WIDE;
  return SCRIPT.map((seg, index) => {
    const placed = {
      ...seg,
      index,
      start,
      end: start + seg.ms,
      from,
      afterHold: index > 1 && SCRIPT[index - 1]!.kind === "hold",
    };
    start += seg.ms;
    from = seg.to;
    return placed;
  });
})();
const TOTAL_MS = PLACED.at(-1)!.end;

/// The width the script asks for `ms` into the drag (its own copy runs in the page).
function widthAt(ms: number): number {
  const seg = PLACED.find((one) => ms < one.end) ?? PLACED.at(-1)!;
  if (seg.kind === "hold") return seg.to;
  const t = Math.min(1, Math.max(0, (ms - seg.start) / seg.ms));
  return Math.round(seg.from + (seg.to - seg.from) * t);
}

// ---- in the page -------------------------------------------------------------------------------

type FrameRec = { t: number; w: number; seg: number; work: number };
type LoafRec = {
  start: number;
  duration: number;
  blocking: number;
  renderStart: number;
  styleAndLayoutStart: number;
  scripts: { invoker: string; fn: string; source: string; duration: number }[];
};
type PerfSample = { interval_ms: number; layout_ms: number; react_ms: number; spans: Record<string, number> };
type DragRun = {
  frames: FrameRec[];
  loaf: LoafRec[];
  longtasks: { start: number; duration: number }[];
  perf?: PerfSample[];
  entryTypes: string[];
};
type StartArgs = { placed: PlacedSeg[]; total: number; driver: "root" | "viewport"; spans: boolean };

/// Runs in the page: records every frame of one drag (and drives it with `driver: root`). Returns at
/// once; `window.__drag` resolves with the run once the script's last segment ended.
function startDragInPage({ placed, total, driver, spans }: StartArgs): void {
  type PerfModule = typeof import("../src/agent-session/acpmux/perf");
  const win = window as unknown as { __acpmuxPerf: PerfModule; __drag?: Promise<DragRun> };
  const perf = spans ? win.__acpmuxPerf.acpmuxPerf : undefined;
  const root = document.getElementById("root")!;
  const segAt = (ms: number) => (placed.find((one) => ms < one.end) ?? placed[placed.length - 1]!).index;
  const widthAt = (ms: number) => {
    const seg = placed.find((one) => ms < one.end) ?? placed[placed.length - 1]!;
    if (seg.kind === "hold") return seg.to;
    const t = Math.min(1, Math.max(0, (ms - seg.start) / seg.ms));
    return Math.round(seg.from + (seg.to - seg.from) * t);
  };
  const entryTypes: string[] = (PerformanceObserver as unknown as { supportedEntryTypes?: string[] })
    .supportedEntryTypes
    ? [...(PerformanceObserver as unknown as { supportedEntryTypes: string[] }).supportedEntryTypes]
    : [];
  const frames: FrameRec[] = [];
  const loafRaw: PerformanceEntry[] = [];
  const longRaw: PerformanceEntry[] = [];
  const observers: PerformanceObserver[] = [];
  const watch = (type: string, into: PerformanceEntry[]) => {
    if (!entryTypes.includes(type)) return;
    const observer = new PerformanceObserver((found) => into.push(...found.getEntries()));
    observer.observe({ type, buffered: false });
    observers.push(observer);
  };
  watch("long-animation-frame", loafRaw);
  watch("longtask", longRaw);
  if (perf) {
    perf.enable();
    perf.resetFrames();
  }
  // One channel for every frame's "rendering finished" task.
  const channel = new MessageChannel();
  const pending: (() => void)[] = [];
  channel.port1.onmessage = () => pending.shift()?.();
  let t0 = -1;
  let last = -1;
  win.__drag = new Promise<DragRun>((resolve) => {
    const finish = () => {
      for (const observer of observers) {
        // Entries the observer has not delivered yet.
        const left = observer.takeRecords();
        for (const entry of left) (entry.entryType === "longtask" ? longRaw : loafRaw).push(entry);
        observer.disconnect();
      }
      channel.port1.close();
      let perfSamples: PerfSample[] | undefined;
      if (perf) {
        const stats = perf.stats(true) as { samples?: PerfSample[] };
        perfSamples = stats.samples;
        perf.enabled = false;
      }
      resolve({
        frames,
        entryTypes,
        longtasks: longRaw.map((entry) => ({ start: entry.startTime - t0, duration: entry.duration })),
        loaf: loafRaw.map((raw) => {
          const entry = raw as PerformanceEntry & {
            blockingDuration?: number;
            renderStart?: number;
            styleAndLayoutStart?: number;
            scripts?: {
              invoker?: string;
              sourceFunctionName?: string;
              sourceURL?: string;
              sourceCharPosition?: number;
              duration: number;
            }[];
          };
          return {
            start: entry.startTime - t0,
            duration: entry.duration,
            blocking: entry.blockingDuration ?? 0,
            renderStart: (entry.renderStart ?? 0) - t0,
            styleAndLayoutStart: (entry.styleAndLayoutStart ?? 0) - t0,
            scripts: (entry.scripts ?? [])
              .slice()
              .sort((a, b) => b.duration - a.duration)
              .slice(0, 4)
              .map((script) => ({
                invoker: script.invoker ?? "",
                fn: script.sourceFunctionName ?? "",
                source: `${(script.sourceURL ?? "").split("/").pop()}@${script.sourceCharPosition ?? -1}`,
                duration: script.duration,
              })),
          };
        }),
        perf: perfSamples,
      });
    };
    const tick = (now: number) => {
      if (t0 < 0) t0 = now;
      const ms = now - t0;
      perf?.markFrame(now, false);
      const start = performance.now();
      let width: number;
      if (driver === "root") {
        width = widthAt(ms);
        if (width !== last) {
          root.style.width = `${width}px`;
          last = width;
        }
      } else width = window.innerWidth;
      const rec: FrameRec = { t: ms, w: width, seg: segAt(ms), work: 0 };
      frames.push(rec);
      const done = ms >= total;
      // A task posted from the frame's callback runs once that frame's rendering step finished.
      pending.push(() => {
        rec.work = performance.now() - start;
        if (done) finish();
      });
      channel.port2.postMessage(0);
      if (!done) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

/// Runs in the page: waits until the rows, their heights and the scroll stop changing for 20 frames
/// (or `maxMs` passed). Returns how long it took and whether it came to rest.
async function restInPage(maxMs: number): Promise<{ ms: number; rested: boolean; rows: number }> {
  const began = performance.now();
  const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll");
  const read = () => {
    const node = scroller();
    if (!node) return "";
    const rows = node.querySelectorAll(".acpmux-thread > .acpmux-row");
    const lastRow = rows[rows.length - 1] as HTMLElement | undefined;
    return `${rows.length}|${node.scrollTop}|${node.scrollHeight}|${lastRow?.dataset.rowId ?? ""}|${lastRow?.offsetHeight ?? 0}`;
  };
  let same = 0;
  let last = "";
  while (performance.now() - began < maxMs && same < 20) {
    await new Promise<number>((resolve) => requestAnimationFrame(resolve));
    const now = read();
    same = now !== "" && now === last ? same + 1 : 0;
    last = now;
  }
  const rows = scroller()?.querySelectorAll(".acpmux-thread > .acpmux-row").length ?? 0;
  return { ms: Math.round(performance.now() - began), rested: same >= 20, rows };
}

// ---- statistics --------------------------------------------------------------------------------

const round2 = (value: number) => Math.round(value * 100) / 100;
/// Nearest-rank percentile of `values`.
const pct = (values: number[], p: number) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))]!;
};
type Stats = {
  frames: number;
  p50_ms: number;
  p95_ms: number;
  max_ms: number;
  over_50ms: number;
  over_budget: number;
  fps_at_p95: number;
  work_p50_ms: number;
  work_p95_ms: number;
  work_max_ms: number;
};
function stats(intervals: number[], work: number[]): Stats {
  const p95 = pct(intervals, 0.95);
  return {
    frames: intervals.length,
    p50_ms: round2(pct(intervals, 0.5)),
    p95_ms: round2(p95),
    max_ms: round2(Math.max(0, ...intervals)),
    over_50ms: intervals.filter((ms) => ms > TARGET_MAX_MS).length,
    over_budget: intervals.filter((ms) => ms > TARGET_P95_MS).length,
    fps_at_p95: p95 > 0 ? round2(1000 / p95) : 0,
    work_p50_ms: round2(pct(work, 0.5)),
    work_p95_ms: round2(pct(work, 0.95)),
    work_max_ms: round2(Math.max(0, ...work)),
  };
}

const PHASES = ["all", "drag", "resume", "settle"] as const;
type Phase = (typeof PHASES)[number];
type Interval = { at: number; ms: number; work: number; seg: number; width: number; phases: Phase[] };

/// Each frame's interval (to the next frame), with the phases it counts in.
function intervalsOf(run: DragRun): Interval[] {
  const out: Interval[] = [];
  const intoSeg = new Map<number, number>();
  for (let index = 0; index + 1 < run.frames.length; index += 1) {
    const frame = run.frames[index]!;
    const seg = PLACED[frame.seg]!;
    const nth = intoSeg.get(seg.index) ?? 0;
    intoSeg.set(seg.index, nth + 1);
    const phases: Phase[] = [];
    if (seg.index > 0) {
      phases.push("all");
      if (seg.kind === "move") {
        phases.push("drag");
        if (seg.afterHold && nth < RESUME_FRAMES) phases.push("resume");
      } else phases.push("settle");
    }
    out.push({
      at: round2(frame.t),
      ms: run.frames[index + 1]!.t - frame.t,
      work: frame.work,
      seg: seg.index,
      width: frame.w,
      phases,
    });
  }
  return out;
}

function phaseStats(intervals: Interval[]): Record<Phase, Stats> {
  return Object.fromEntries(
    PHASES.map((phase) => {
      const mine = intervals.filter((one) => one.phases.includes(phase));
      return [
        phase,
        stats(
          mine.map((one) => one.ms),
          mine.map((one) => one.work),
        ),
      ];
    }),
  ) as Record<Phase, Stats>;
}

/// p95 of each acpmuxPerf span (and layout and React ms) over the frames of each phase.
function spanStats(intervals: Interval[], samples: PerfSample[] | undefined) {
  if (!samples) return undefined;
  const out: Record<string, Record<string, number>> = {};
  for (const phase of PHASES) {
    const at = intervals
      .map((one, index) => [one, samples[index]] as const)
      .filter(([one]) => one.phases.includes(phase));
    const names = new Set(at.flatMap(([, sample]) => Object.keys(sample?.spans ?? {})));
    const row: Record<string, number> = {
      layout_ms_p95: round2(
        pct(
          at.map(([, sample]) => sample?.layout_ms ?? 0),
          0.95,
        ),
      ),
      react_ms_p95: round2(
        pct(
          at.map(([, sample]) => sample?.react_ms ?? 0),
          0.95,
        ),
      ),
      layout_ms_max: round2(Math.max(0, ...at.map(([, sample]) => sample?.layout_ms ?? 0))),
      react_ms_max: round2(Math.max(0, ...at.map(([, sample]) => sample?.react_ms ?? 0))),
    };
    for (const name of names) {
      const values = at.map(([, sample]) => sample?.spans?.[name] ?? 0);
      row[`${name}_p95`] = round2(pct(values, 0.95));
      row[`${name}_max`] = round2(Math.max(0, ...values));
    }
    out[phase] = row;
  }
  return out;
}

/// The frames over 50 ms, with what the engine and the pane say ran in them.
function gapsOf(intervals: Interval[], run: DragRun, round: string) {
  return intervals
    .map((one, index) => ({ one, index }))
    .filter(({ one }) => one.ms > TARGET_MAX_MS)
    .map(({ one, index }) => {
      const end = one.at + one.ms;
      const overlaps = (start: number, duration: number) => start < end && start + duration > one.at;
      const sample = run.perf?.[index];
      return {
        round,
        at_ms: one.at,
        interval_ms: round2(one.ms),
        work_ms: round2(one.work),
        seg: one.seg,
        seg_kind: PLACED[one.seg]!.kind,
        width: one.width,
        phases: one.phases,
        loaf: run.loaf
          .filter((entry) => overlaps(entry.start, entry.duration))
          .map((entry) => ({
            start: round2(entry.start),
            duration: round2(entry.duration),
            blocking: round2(entry.blocking),
            // Script, then style and layout, then paint, as Chromium splits the frame.
            script_ms: round2(
              Math.max(0, (entry.renderStart > 0 ? entry.renderStart : entry.start + entry.duration) - entry.start),
            ),
            render_ms: round2(entry.renderStart > 0 ? entry.start + entry.duration - entry.renderStart : 0),
            style_layout_ms: round2(
              entry.styleAndLayoutStart > 0 ? entry.start + entry.duration - entry.styleAndLayoutStart : 0,
            ),
            scripts: entry.scripts.map((script) => ({ ...script, duration: round2(script.duration) })),
          })),
        longtasks: run.longtasks
          .filter((task) => overlaps(task.start, task.duration))
          .map((task) => round2(task.duration)),
        spans: sample
          ? {
              layout_ms: round2(sample.layout_ms),
              react_ms: round2(sample.react_ms),
              ...Object.fromEntries(Object.entries(sample.spans).map(([name, ms]) => [name, round2(ms)])),
            }
          : undefined,
      };
    });
}

const line = (name: string, s: Stats) =>
  `${name}: frames=${s.frames} p50=${s.p50_ms} p95=${s.p95_ms} max=${s.max_ms} over50=${s.over_50ms} fps@p95=${s.fps_at_p95}`;

// ---- one drag ----------------------------------------------------------------------------------

async function drag(page: Page, spans: boolean): Promise<DragRun> {
  const args: StartArgs = { placed: PLACED, total: TOTAL_MS, driver: DRIVER, spans };
  if (DRIVER === "viewport") await page.setViewportSize({ width: WIDE, height: HEIGHT });
  else
    await page.evaluate((wide) => {
      document.getElementById("root")!.style.width = `${wide}px`;
    }, WIDE);
  await page.evaluate(restInPage, 20_000);
  await page.evaluate(startDragInPage, args);
  if (DRIVER === "viewport") {
    // The runner moves the page's edge on its own clock, as the app's divider does; the page labels
    // its frames by its own clock from its first frame, a round trip apart.
    const began = performance.now();
    let last = WIDE;
    for (;;) {
      const ms = performance.now() - began;
      if (ms >= TOTAL_MS) break;
      const width = widthAt(ms);
      if (width !== last) {
        await page.setViewportSize({ width, height: HEIGHT });
        last = width;
      } else await Bun.sleep(4);
    }
  }
  return page.evaluate(() => (window as unknown as { __drag: Promise<DragRun> }).__drag);
}

/// One more drag under Chromium's sampling profiler: its heaviest functions by self time.
async function profiled(page: Page): Promise<{ self_ms: number; fn: string }[]> {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Profiler.enable");
  await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
  await cdp.send("Profiler.start");
  await drag(page, false);
  const { profile } = (await cdp.send("Profiler.stop")) as {
    profile: {
      nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
      samples: number[];
      timeDeltas: number[];
    };
  };
  await cdp.detach();
  const byNode = new Map(profile.nodes.map((node) => [node.id, node.callFrame]));
  const self = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const frame = byNode.get(id)!;
    const key = `${frame.functionName || "(anon)"} ${frame.url.split("/").slice(-2).join("/").split("?")[0]}:${frame.lineNumber + 1}`;
    self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
  });
  return [...self]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 30)
    .map(([fn, ms]) => ({ fn, self_ms: round2(ms) }));
}

// ---- the run -----------------------------------------------------------------------------------

fs.mkdirSync(OUT, { recursive: true });
const engines: Record<string, BrowserType> = { chromium, webkit };
const served = await serveBenchPage("/bench/pane-resize-drag/index.html", { dev: DEV, unminified: PROFILE });
const build = buildLabel({ dev: DEV });
const cases: Record<string, unknown>[] = [];
const failures: string[] = [];
console.log(
  `pane-resize-drag build=${build} driver=${DRIVER} engines=${ENGINES.join(",")} turns=${TURNS.join(",")} rounds=${ROUNDS} ` +
    `drag=${WIDE}->${NARROW}->${WIDE}px over ${TOTAL_MS} ms (pauses ${PLACED.filter(
      (seg) => seg.kind === "hold" && seg.index > 0,
    )
      .map((seg) => seg.ms)
      .join("/")} ms) out=${OUT}`,
);
try {
  for (const engineName of ENGINES) {
    let browser: Browser;
    try {
      browser = await engines[engineName]!.launch({ headless: true, timeout: 60_000 });
    } catch (error) {
      const why = `${engineName} did not launch: ${String(error).split("\n")[0]}`;
      console.error(`pane-resize-drag: ${why}`);
      failures.push(why);
      continue;
    }
    const version = browser.version();
    let reactChecked = false;
    try {
      for (const turns of TURNS) {
        const page = await browser.newPage({
          viewport: { width: DRIVER === "viewport" ? WIDE : WIDE + 40, height: HEIGHT },
        });
        page.setDefaultTimeout(180_000);
        try {
          await gotoBenchPage(page, served);
          if (!reactChecked) {
            await requireProductionReact(page, { dev: DEV });
            reactChecked = true;
          }
          await page.waitForFunction(() => "__seedLong" in window);
          const seedStart = Date.now();
          const seeded = await page.evaluate((count) => {
            const win = window as unknown as { __seedLong: (turns: number) => { turns: number; rows: number } };
            return win.__seedLong(count);
          }, turns);
          const rest = await page.evaluate(restInPage, 120_000);
          const seedMs = Date.now() - seedStart;
          const shaped = await page.evaluate(() =>
            (window as unknown as { __shapedRows: () => number }).__shapedRows(),
          );
          await drag(page, false); // warm-up, not reported
          const runs: DragRun[] = [];
          for (let round = 0; round < ROUNDS; round += 1) runs.push(await drag(page, false));
          const spanRun = SPANS ? await drag(page, true) : undefined;
          const profile = PROFILE && engineName === "chromium" ? await profiled(page) : undefined;

          const measured = runs.map(intervalsOf);
          const pooled = measured.flat();
          const phases = phaseStats(pooled);
          const spanIntervals = spanRun ? intervalsOf(spanRun) : undefined;
          const gaps = [
            ...runs.flatMap((run, round) => gapsOf(measured[round]!, run, `round${round}`)),
            ...(spanRun && spanIntervals ? gapsOf(spanIntervals, spanRun, "spans") : []),
          ];
          const met = PHASES.every(
            (phase) =>
              phases[phase].frames === 0 ||
              (phases[phase].p95_ms <= TARGET_P95_MS && phases[phase].max_ms <= TARGET_MAX_MS),
          );
          const result = {
            engine: engineName,
            browser: version,
            turns,
            rows: seeded.rows,
            shaped_rows: shaped,
            mounted_rows: rest.rows,
            seed_ms: seedMs,
            seed_rested: rest.rested,
            phases,
            target: { p95_ms: round2(TARGET_P95_MS), max_ms: TARGET_MAX_MS, met },
            per_round: measured.map(phaseStats),
            spans_run:
              spanRun && spanIntervals
                ? { phases: phaseStats(spanIntervals), spans: spanStats(spanIntervals, spanRun.perf) }
                : undefined,
            entry_types: runs[0]?.entryTypes.filter((type) => ["long-animation-frame", "longtask"].includes(type)),
            loaf_count: runs.reduce((sum, run) => sum + run.loaf.length, 0),
            longtask_count: runs.reduce((sum, run) => sum + run.longtasks.length, 0),
            gaps: gaps.sort((a, b) => b.interval_ms - a.interval_ms).slice(0, 40),
            // Each phase's intervals over every measured round, for cmux-bench rows.
            intervals: Object.fromEntries(
              PHASES.map((phase) => [
                phase,
                pooled.filter((one) => one.phases.includes(phase)).map((one) => round2(one.ms)),
              ]),
            ),
            profile,
          };
          const raw = {
            ...result,
            runs: runs.map((run, round) => ({ round, frames: run.frames, loaf: run.loaf, longtasks: run.longtasks })),
            spans_frames: spanRun ? { frames: spanRun.frames, perf: spanRun.perf, loaf: spanRun.loaf } : undefined,
          };
          fs.writeFileSync(path.join(OUT, `pane-resize-drag-${engineName}-t${turns}.json`), JSON.stringify(raw));
          cases.push(result);
          console.log(
            `pane-resize-drag engine=${engineName} turns=${turns} rows=${seeded.rows} seed_ms=${seedMs} ` +
              PHASES.map((phase) => line(phase, phases[phase])).join(" | ") +
              ` | target(p95<=${round2(TARGET_P95_MS)}, max<=${TARGET_MAX_MS}): ${met ? "MET" : "MISSED"}`,
          );
          if (result.spans_run?.spans)
            console.log(
              `pane-resize-drag engine=${engineName} turns=${turns} spans(drag)=${JSON.stringify(result.spans_run.spans.drag)} ` +
                `spans(settle)=${JSON.stringify(result.spans_run.spans.settle)}`,
            );
          for (const gap of result.gaps.slice(0, 5))
            console.log(`pane-resize-drag engine=${engineName} turns=${turns} gap ${JSON.stringify(gap)}`);
          for (const fn of profile?.slice(0, 20) ?? [])
            console.log(`pane-resize-drag engine=${engineName} turns=${turns} profile self_ms=${fn.self_ms} ${fn.fn}`);
          console.log(
            `PANE_RESIZE_DRAG ${JSON.stringify({ engine: engineName, turns, build, driver: DRIVER, met, ...Object.fromEntries(PHASES.map((phase) => [phase, phases[phase]])) })}`,
          );
          perfRow({
            name: `pane_resize_drag.${engineName}.t${turns}.interval_ms`,
            p50: phases.all.p50_ms,
            p95: phases.all.p95_ms,
            target: round2(TARGET_P95_MS),
          });
        } catch (error) {
          const why = `${engineName} turns=${turns}: ${String(error).split("\n")[0]}`;
          console.error(`pane-resize-drag: ${why}`);
          failures.push(why);
        } finally {
          await page.close();
        }
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await served.close();
}

const summary = {
  schema: "pane-resize-drag/v1",
  build,
  driver: DRIVER,
  wide: WIDE,
  narrow: NARROW,
  rounds: ROUNDS,
  resume_frames: RESUME_FRAMES,
  script: PLACED.map(({ kind, start, end, from, to }) => ({ kind, start, end, from, to })),
  host: { platform: process.platform, cpus: os.cpus().length },
  failures,
  cases,
};
fs.writeFileSync(path.join(OUT, "summary.json"), JSON.stringify(summary, null, 1));
fs.writeFileSync(
  path.join(OUT, "summary.txt"),
  cases
    .map((one) => {
      const phases = one.phases as Record<Phase, Stats>;
      return `${String(one.engine)} t${String(one.turns)}: ${PHASES.map((phase) => line(phase, phases[phase])).join(" | ")}`;
    })
    .join("\n") + (failures.length ? `\nfailures:\n${failures.join("\n")}\n` : "\n"),
);
console.log(
  `pane-resize-drag: wrote ${cases.length} case(s) to ${OUT}${failures.length ? `; ${failures.length} failed` : ""}`,
);
// A case that could not run is a failed bench; a slow frame is not (report only).
if (cases.length === 0 || failures.length > 0) process.exit(1);
