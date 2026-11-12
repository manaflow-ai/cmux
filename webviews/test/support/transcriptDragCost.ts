// A MEASURE, not a test of behavior, and only for a "never merges" branch: the main-thread work of
// each frame of a drag of the divider beside a chat (one new width each frame), for a reader
// scrolled up and for a view that follows the latest row, at two chat lengths. It prints one line
// for each cell (ms: p50, p95, p99, max) so that two arms of one CI round can be compared. It has no
// bound: a shared CI runner's clock is no budget.
//
// A frame's work is the time from the width write (in the frame's animation callback) to a task
// posted from that callback, which runs once the frame's rendering step (style, layout, the
// transcript's ResizeObservers and the React commits they run, paint) finished: the same read as
// bench/transcript-resize-frame.bench.ts. `flow` counts only the frames whose rows were in flow
// when the frame ended; the first steps of each drag are not (the transcript flows from its third
// step), so `all` holds both kinds.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { Browser, BrowserType, Page } from "playwright";
import { probeEngineOrSkip } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

export type DragCostPart = {
  file: string;
  engine: BrowserType;
  engineName: "chromium" | "webkit";
  configFile: string;
};

const WIDE = 800;
const NARROW = 640;
const STEPS = 24;
/// Drags each way in a cell.
const ROUNDS = 4;

/// Runs in the page: the pane `width` wide, at rest (nothing moved for 20 frames), at the chat's end
/// when `toEnd`.
async function restInPage({ width, toEnd }: { width: number; toEnd: boolean }): Promise<number> {
  const root = document.getElementById("root")!;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  const rest = async () => {
    let same = 0;
    let last = "";
    for (let count = 0; count < 900 && same < 20; count += 1) {
      await frame();
      const row = scroller.querySelector<HTMLElement>(".acpmux-thread > .acpmux-row");
      const now = row
        ? JSON.stringify([
            row.dataset.rowId,
            Math.round(row.getBoundingClientRect().top),
            scroller.scrollTop,
            scroller.scrollHeight,
            scroller.clientWidth,
          ])
        : "";
      same = now !== "" && now === last ? same + 1 : 0;
      last = now;
    }
    if (same < 20) throw new Error("the transcript did not come to rest in 900 frames");
  };
  root.style.width = `${width}px`;
  await rest();
  if (toEnd) {
    scroller.scrollTop = scroller.scrollHeight;
    await rest();
  }
  return Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
}

type Cost = { all: number[]; flow: number[]; gap: number; mounted: number; fromEnd: number; view: number };

/// Runs in the page: `rounds` drags from `wide` to `narrow` and back, one width each frame.
async function costInPage({
  wide,
  narrow,
  steps,
  rounds,
}: {
  wide: number;
  narrow: number;
  steps: number;
  rounds: number;
}): Promise<Cost> {
  const root = document.getElementById("root")!;
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
  // The transcript ends a live resize 120 ms after its last width: 20 frames is past that at 60 Hz
  // and at 120 Hz it is not, so this waits by the clock too.
  const settle = async () => {
    const from = performance.now();
    let frames = 0;
    while (frames < 20 || performance.now() - from < 400) {
      await frame();
      frames += 1;
    }
  };
  const all: number[] = [];
  const flow: number[] = [];
  let gap = 0;
  const drag = (from: number, to: number) =>
    new Promise<void>((done) => {
      const widths = Array.from({ length: steps }, (_, index) =>
        Math.round(from + ((to - from) * (index + 1)) / steps),
      );
      let index = 0;
      let stepped = 0;
      const tick = () => {
        if (index >= widths.length) {
          done();
          return;
        }
        const start = performance.now();
        if (index > 0) gap = Math.max(gap, start - stepped);
        stepped = start;
        root.style.width = `${widths[index]}px`;
        index += 1;
        const channel = new MessageChannel();
        channel.port1.onmessage = () => {
          const work = performance.now() - start;
          all.push(work);
          if (document.querySelector(".acpmux-thread.acpmux-thread--flow")) flow.push(work);
        };
        channel.port2.postMessage(0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
  const fromEnd = Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
  const mounted = scroller.querySelectorAll(".acpmux-thread > .acpmux-row").length;
  for (let round = 0; round < rounds; round += 1) {
    await drag(wide, narrow);
    await settle();
    await drag(narrow, wide);
    await settle();
  }
  return { all, flow, gap: Math.round(gap * 10) / 10, mounted, fromEnd, view: scroller.clientHeight };
}

const stats = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (part: number) =>
    sorted.length === 0
      ? null
      : Math.round(sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * part))]! * 100) / 100;
  return { n: sorted.length, p50: at(0.5), p95: at(0.95), p99: at(0.99), max: at(1) };
};

/// Call inside the part's `requireBrowserLane` callback.
export async function dragCost({ file, engine, engineName, configFile }: DragCostPart): Promise<void> {
  setDefaultTimeout(240_000);
  if (!(await probeEngineOrSkip(file, engineName, engine))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "../..");
  const pagePath = "/test/browser/transcript-fling.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, pagePath);
    browser = await engine.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (rows: number): Promise<Page> => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1000, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${pagePath}`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate((px) => {
      document.getElementById("root")!.style.width = `${px}px`;
    }, WIDE);
    await page.evaluate(`window.__debug.seedRows(${rows})`);
    return page;
  };

  for (const rows of [150, 1500]) {
    for (const view of ["scrolled", "follow"] as const) {
      test(`measure: frame work of a drag, ${rows} rows, ${view}`, async () => {
        const page = await open(rows);
        await page.evaluate(restInPage, { width: WIDE, toEnd: true });
        if (view === "scrolled") {
          const box = (await page.locator(".acpmux-scroll").boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.mouse.wheel(0, -2400);
          // fixed-wait: the one-second input hold after a wheel is a timer in the product, with no state to wait on.
          await page.waitForTimeout(1_150);
          await page.evaluate(restInPage, { width: WIDE, toEnd: false });
        }
        const cost = await page.evaluate(costInPage, { wide: WIDE, narrow: NARROW, steps: STEPS, rounds: ROUNDS });
        await page.close();
        console.log(
          `${file}: cost ${JSON.stringify({
            rows,
            view,
            engine: engineName,
            paneView: cost.view,
            mounted: cost.mounted,
            fromEnd: cost.fromEnd,
            gapMs: cost.gap,
            all: stats(cost.all),
            flow: stats(cost.flow),
          })}`,
        );
        expect(cost.all.length, "frames read").toBe(STEPS * ROUNDS * 2);
        if (view === "scrolled") expect(cost.fromEnd, "px the reader is up from the chat's end").toBeGreaterThan(1000);
        else expect(cost.fromEnd, "px the view is from the chat's end").toBeLessThanOrEqual(2);
      });
    }
  }
}
