// l10n-allow-file: benchmark output, not shipped UI.
// A stable, report-only fling benchmark for the transcript replacement work in RFD 0040 decision 2.
// The web arm renders the current transcript row shape at 100k rows. The bare arm draws the same row count as
// plain text and both arms use the named fling step sequence, leaving a floor for a future native arm to join.
// The transcript arm is the shipped React transcript (VirtualTranscript, through test/browser/transcript-fling.html
// as transcript-scroll-frame.bench.ts drives it) at TRANSCRIPT_ROWS (default 3,000, RFD 0121's fling row), flung
// bottom to top by the pane's own debug fling for FLING_SECONDS: the "before" the native transcript is measured
// against. Linux headless: `bun bench/transcript-fling.bench.ts`; a Mac: perf-bench.sh transcriptfling=on.
// TRANSCRIPT_FLING_OUT=path writes every arm as JSON lines for perf-bench.sh's BENCH.md section; ARMS=transcript
// (comma list of web,bare,transcript) runs a subset.
/// <reference types="bun" />
import { appendFileSync, writeFileSync } from "node:fs";
import { chromium } from "./browsers";
import { perfRow } from "./perfRow";
import { gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";

const ROWS = Number(process.env.ROWS ?? 100_000);
const PAGES = Number(process.env.PAGES ?? 24);
const TRANSCRIPT_ROWS = Number(process.env.TRANSCRIPT_ROWS ?? 3000);
const FLING_SECONDS = Number(process.env.FLING_SECONDS ?? 3);
const FLING_ROUNDS = Number(process.env.FLING_ROUNDS ?? 3);
const ARMS = new Set((process.env.ARMS ?? "web,bare,transcript").split(",").map((arm) => arm.trim()));
const OUT = process.env.TRANSCRIPT_FLING_OUT;
const LATE_FRAME_MS = 1000 / 120;
const SCHEMA = "cmux/transcript-fling/v1";
const FLING_STEPS = [1500, 2400, 1900, 3000, 2100];

type Arm = {
  schema: typeof SCHEMA;
  arm: "web" | "bare" | "transcript" | "native";
  engine: "chromium";
  fixture: "flat" | "harness";
  rows: number;
  mode: "fling";
  frames: number;
  frame_p50_ms: number;
  frame_p95_ms: number;
  frame_max_ms: number;
  late_frames: number;
  blank_frames: number;
};

const percentile = (values: number[], p: number) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
};

async function runWebArm(): Promise<Arm> {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.setContent(
      '<main id="transcript" class="web-transcript"><div id="rows"></div></main><style>' +
        ":root,body{margin:0;height:100%;overflow:hidden}#transcript{height:100%;overflow:auto;box-sizing:border-box;padding:12px 16px;font:14px/24px system-ui,sans-serif}.web-row{box-sizing:border-box;min-height:40px;padding:8px 12px;border-bottom:1px solid #e5e7eb;contain:layout paint}.web-row.user{background:#f7f8fa}.web-row.assistant{background:#fff}" +
        "</style>",
    );
    await page.locator("#rows").evaluate((node, rows) => {
      const fragment = document.createDocumentFragment();
      for (let index = 0; index < (rows as number); index++) {
        const row = document.createElement("div");
        row.className = `web-row ${index % 2 ? "assistant" : "user"}`;
        row.textContent = `${index % 2 ? "assistant" : "user"}-${Math.floor(index / 2) + 1}: transcript row ${index + 1}`;
        fragment.append(row);
      }
      node.append(fragment);
    }, ROWS);
    const result = await page.evaluate(
      ({ pages, steps }) =>
        new Promise<{ intervals: number[]; blankFrames: number[] }>((resolve) => {
          const scroller = document.querySelector<HTMLElement>("#transcript")!;
          scroller.scrollTop = scroller.scrollHeight;
          const intervals: number[] = [];
          const blankFrames: number[] = [];
          let previous = 0;
          let frame = 0;
          const tick = (now: number) => {
            if (previous) intervals.push(now - previous);
            previous = now;
            const box = scroller.getBoundingClientRect();
            const visible = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            if (!visible?.closest(".web-row")) blankFrames.push(frame);
            scroller.scrollTop = Math.max(0, scroller.scrollTop - steps[frame % steps.length]!);
            frame += 1;
            if (frame >= pages * 120 || scroller.scrollTop <= 0) resolve({ intervals, blankFrames });
            else requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        }),
      { pages: PAGES, steps: FLING_STEPS },
    );
    const rounded = (value: number) => Math.round(value * 100) / 100;
    return {
      schema: SCHEMA,
      arm: "web",
      engine: "chromium",
      fixture: "flat",
      rows: ROWS,
      mode: "fling",
      frames: result.intervals.length,
      frame_p50_ms: rounded(percentile(result.intervals, 50)),
      frame_p95_ms: rounded(percentile(result.intervals, 95)),
      frame_max_ms: rounded(Math.max(0, ...result.intervals)),
      late_frames: result.intervals.filter((interval) => interval > LATE_FRAME_MS).length,
      blank_frames: result.blankFrames.length,
    };
  } finally {
    await browser.close();
  }
}

async function runBareArm(frames: number): Promise<Arm> {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
    await page.setContent('<main id="transcript" class="bare-scroll"><pre id="text"></pre></main>');
    await page.locator("#text").evaluate((node, rows) => {
      node.textContent = Array.from(
        { length: rows as number },
        (_, index) => `${index % 2 ? "assistant" : "user"}-${Math.floor(index / 2) + 1}: transcript row ${index + 1}`,
      ).join("\n");
    }, ROWS);
    await page.addStyleTag({
      content:
        ":root,body{margin:0;height:100%;overflow:hidden}body{font:14px/40px system-ui,sans-serif}#transcript{height:100%;overflow:auto;box-sizing:border-box;padding:12px 16px}#text{margin:0;white-space:pre-wrap;overflow-wrap:anywhere}",
    });
    const result = await page.evaluate(
      ({ frames, steps }) =>
        new Promise<{ intervals: number[]; blankFrames: number[] }>((resolve) => {
          const scroller = document.querySelector<HTMLElement>("#transcript")!;
          scroller.scrollTop = scroller.scrollHeight;
          const intervals: number[] = [];
          const blankFrames: number[] = [];
          let previous = 0;
          let frame = 0;
          const tick = (now: number) => {
            if (previous) intervals.push(now - previous);
            previous = now;
            const box = scroller.getBoundingClientRect();
            const visible = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            if (!visible?.closest("#text") || scroller.scrollHeight <= scroller.clientHeight) blankFrames.push(frame);
            scroller.scrollTop = Math.max(0, scroller.scrollTop - steps[frame % steps.length]!);
            frame += 1;
            if (frame >= frames || scroller.scrollTop <= 0) resolve({ intervals, blankFrames });
            else requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        }),
      { frames, steps: FLING_STEPS, lateFrameMs: LATE_FRAME_MS },
    );
    const rounded = (value: number) => Math.round(value * 100) / 100;
    return {
      schema: SCHEMA,
      arm: "bare",
      engine: "chromium",
      fixture: "flat",
      rows: ROWS,
      mode: "fling",
      frames: result.intervals.length,
      frame_p50_ms: rounded(percentile(result.intervals, 50)),
      frame_p95_ms: rounded(percentile(result.intervals, 95)),
      frame_max_ms: rounded(Math.max(0, ...result.intervals)),
      late_frames: result.intervals.filter((interval) => interval > LATE_FRAME_MS).length,
      blank_frames: result.blankFrames.length,
    };
  } finally {
    await browser.close();
  }
}

/// The shipped React transcript: FLING_ROUNDS flings (after one warm-up) of FLING_SECONDS each, bottom to top,
/// one scrollTop step per animation frame (debug.ts startFling). Intervals come from the pane's own frame ring;
/// blank frames are the pane's model-blank count (no mounted row under the viewport).
async function runTranscriptArm(): Promise<Arm> {
  const served = await serveBenchPage("/test/browser/transcript-fling.html");
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
    await gotoBenchPage(page, served);
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate(`window.__debug.seedRows(${TRANSCRIPT_ROWS})`);
    type Debug = {
      startFling(
        seconds: number,
        options: { wait: boolean },
      ): Promise<{ frames: number; running: boolean; distance_px: number }>;
      perfStats(options: { raw: boolean }): { blank_frames: number; samples?: { interval_ms: number }[] };
    };
    const fling = () =>
      page.evaluate(async (seconds) => {
        const debug = (window as unknown as { __debug: Debug }).__debug;
        const run = await debug.startFling(seconds, { wait: true });
        const { samples, blank_frames } = debug.perfStats({ raw: true });
        if (!samples?.length || run.running || run.distance_px <= 0)
          throw new Error(`transcript-fling: incomplete fling ${JSON.stringify(run)}`);
        return { intervals: samples.map((sample) => sample.interval_ms), blank: blank_frames };
      }, FLING_SECONDS);
    await fling();
    const intervals: number[] = [];
    let blank = 0;
    for (let round = 0; round < FLING_ROUNDS; round += 1) {
      const run = await fling();
      intervals.push(...run.intervals);
      blank += run.blank;
    }
    const rounded = (value: number) => Math.round(value * 100) / 100;
    return {
      schema: SCHEMA,
      arm: "transcript",
      engine: "chromium",
      fixture: "harness",
      rows: TRANSCRIPT_ROWS,
      mode: "fling",
      frames: intervals.length,
      frame_p50_ms: rounded(percentile(intervals, 50)),
      frame_p95_ms: rounded(percentile(intervals, 95)),
      frame_max_ms: rounded(Math.max(0, ...intervals)),
      late_frames: intervals.filter((interval) => interval > LATE_FRAME_MS).length,
      blank_frames: blank,
    };
  } finally {
    await browser.close();
    await served.close();
  }
}

if (OUT) writeFileSync(OUT, "");
const report = (arm: Arm) => {
  console.log(`TRANSCRIPT_FLING_JSON ${JSON.stringify(arm)}`);
  if (OUT) appendFileSync(OUT, `${JSON.stringify(arm)}\n`);
  perfRow({
    name: `transcript_fling.${arm.arm}.frame_interval`,
    p50: arm.frame_p50_ms,
    p95: arm.frame_p95_ms,
    target: 8.33,
  });
};
let webFrames = PAGES * 120;
if (ARMS.has("web")) {
  const web = await runWebArm();
  webFrames = web.frames;
  report(web);
}
if (ARMS.has("bare")) report(await runBareArm(webFrames));
if (ARMS.has("transcript")) report(await runTranscriptArm());
