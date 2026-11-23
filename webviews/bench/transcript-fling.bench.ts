// l10n-allow-file: benchmark output, not shipped UI.
// A stable, report-only fling benchmark for the transcript replacement work in RFD 0040 decision 2.
// The web arm renders the current transcript row shape at 100k rows. The bare arm draws the same row count as
// plain text and both arms use the named fling step sequence, leaving a floor for a future native arm to join.
/// <reference types="bun" />
import { chromium } from "./browsers";
import { perfRow } from "./perfRow";

const ROWS = Number(process.env.ROWS ?? 100_000);
const PAGES = Number(process.env.PAGES ?? 24);
const LATE_FRAME_MS = 1000 / 120;
const SCHEMA = "cmux/transcript-fling/v1";
const FLING_STEPS = [1500, 2400, 1900, 3000, 2100];

type Arm = {
  schema: typeof SCHEMA;
  arm: "web" | "bare" | "native";
  engine: "chromium";
  fixture: "flat";
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

const web = await runWebArm();
console.log(`TRANSCRIPT_FLING_JSON ${JSON.stringify(web)}`);
perfRow({ name: "transcript_fling.web.frame_interval", p50: web.frame_p50_ms, p95: web.frame_p95_ms, target: 8.33 });
const bare = await runBareArm(web.frames);
console.log(`TRANSCRIPT_FLING_JSON ${JSON.stringify(bare)}`);
perfRow({ name: "transcript_fling.bare.frame_interval", p50: bare.frame_p50_ms, p95: bare.frame_p95_ms, target: 8.33 });
