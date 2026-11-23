// l10n-allow-file: benchmark output, not shipped UI.
// A stable, report-only fling benchmark for the transcript replacement work in RFD 0040 decision 2.
// The web arm runs transcript-scroll-up's existing 100k-row fling driver. The bare arm draws the same row count as
// plain text and drives the same per-frame fling steps, leaving a floor for a future native arm to join.
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

function numberFromWeb(output: string, field: string): number {
  const match = output.match(new RegExp(`transcript-scroll-up chromium ${field}: ([^\\n]+)`));
  if (!match) throw new Error(`web arm did not report ${field}; output tail:\n${output.slice(-2000)}`);
  const value = Number(JSON.parse(match[1]!));
  if (!Number.isFinite(value)) throw new Error(`web arm reported a non-number for ${field}`);
  return value;
}

async function runWebArm(): Promise<Arm> {
  const child = Bun.spawn([process.execPath, "bench/transcript-scroll-up.bench.ts"], {
    cwd: import.meta.dir.replace(/\/bench$/, ""),
    env: {
      ...process.env,
      ENGINES: "chromium",
      FIXTURE: "flat",
      ROWS: String(ROWS),
      MODE: "fling",
      PAGES: String(PAGES),
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
  await child.exited;
  const output = `${stdout}\n${stderr}`;
  return {
    schema: SCHEMA,
    arm: "web",
    engine: "chromium",
    fixture: "flat",
    rows: ROWS,
    mode: "fling",
    frames: numberFromWeb(output, "frames"),
    frame_p50_ms: numberFromWeb(output, "frameP50"),
    frame_p95_ms: numberFromWeb(output, "frameP95"),
    frame_max_ms: numberFromWeb(output, "frameMax"),
    late_frames: numberFromWeb(output, "lateFrames"),
    blank_frames: numberFromWeb(output, "blankFrames"),
  };
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
