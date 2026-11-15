// A fast fling down a long chat keeps rows under the view (cx-j33s4). The frame pacing bench's
// fling (debug.ts startFling: 5000 rows, bottom to top in 3 s) left part of the view empty on
// 97-104 of 181 frames at the capped render rate: one frame there scrolls about as far as the
// transcript mounted ahead of the reader (App.tsx), so the next frame's view fell past it.
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { startScrollCoverage } from "../bench/scrollCoverage";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fling.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fling: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript fling", () => test("webkit", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-fling.html");
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// Scrolls the transcript from one end by `steps[i]` viewports on frame i, as a fling sets the
  /// offset from a frame callback, and counts the frames whose view the mounted rows leave partly
  /// empty. The step is fixed per frame, not per millisecond, so a slow runner scrolls the same path
  /// the bench's 60 fps fling does.
  const steppedFling = async ({ steps, down }: { steps: number[]; down: boolean }) => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const end = () => scroller.scrollHeight - scroller.clientHeight;
    scroller.scrollTop = down ? 0 : end();
    await window.cmuxPaintFrame();
    await window.cmuxPaintFrame();
    let blank = 0;
    let frames = 0;
    const blanks: string[] = [];
    /// Viewports of rows mounted as each frame painted, the frame's built work.
    const mounted: number[] = [];
    for (const step of steps) {
      // The frame's callback moves the view; the view is read as that frame painted it.
      await window.cmuxPaintFrame(() => {
        const by = step * scroller.clientHeight;
        scroller.scrollTop = down ? Math.min(end(), scroller.scrollTop + by) : Math.max(0, scroller.scrollTop - by);
      });
      // Mounted rows in runs of consecutive positions; one run has to hold the whole view.
      const view = scroller.getBoundingClientRect();
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((row) => ({ index: Number(row.getAttribute("aria-posinset")), rect: row.getBoundingClientRect() }))
        .sort((a, b) => a.index - b.index);
      const runs: { top: number; bottom: number }[] = [];
      rows.forEach((row, at) => {
        if (at > 0 && row.index === rows[at - 1].index + 1) runs.at(-1)!.bottom = row.rect.bottom;
        else runs.push({ top: row.rect.top, bottom: row.rect.bottom });
      });
      mounted.push(rows.reduce((sum, row) => sum + row.rect.height, 0) / scroller.clientHeight);
      const bottom = Math.min(view.bottom, view.top + scroller.scrollHeight - scroller.scrollTop);
      // The thread's own top padding is above its first row: a view at the top shows it, empty by
      // design (every up fling and drag ended on a "blank" frame at scrollTop 0 for its 16 px).
      const thread = scroller.querySelector<HTMLElement>(".acpmux-thread")!;
      const top = view.top + Math.max(0, parseFloat(getComputedStyle(thread).paddingTop) - scroller.scrollTop);
      frames += 1;
      if (!runs.some((run) => run.top <= top + 0.5 && run.bottom >= bottom - 0.5)) {
        blank += 1;
        // What a blank frame drew, for the log: its frame, the step, the offset, and the mounted
        // runs against the view (px from its top), to tell a lead too short from a late render.
        blanks.push(
          `#${frames}/${step}vp@${Math.round(scroller.scrollTop)}: ${runs.map((run) => `${Math.round(run.top - view.top)}..${Math.round(run.bottom - view.top)}`).join(" ")}`,
        );
      }
      if (scroller.scrollTop === (down ? end() : 0)) break;
    }
    const sorted = [...mounted].sort((a, b) => a - b);
    const mountedViewports = Math.round((sorted[Math.floor(sorted.length / 2)] ?? 0) * 100) / 100;
    return { frames, blank, blanks, mountedViewports };
  };

  test("mounted row heights read after sibling writes and settle before the first paint", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__batchMeasure" in window);
      // This synthetic renderer owns its exact height; remove the article's generic minimum
      // and trailing padding so its geometry directly exposes a stale placement estimate.
      await page.addStyleTag({ content: ".acpmux-row.acpmux-batch-measure{min-height:0;padding-bottom:0}" });
      for (const version of [1, 2]) {
        const result = await page.evaluate(async (revision) => {
          const w = window as unknown as { __batchMeasure: (version: number) => string[] };
          let trace: string[] = [];
          await window.cmuxPaintFrame(() => {
            trace = w.__batchMeasure(revision);
          });
          const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => {
            const rect = row.getBoundingClientRect();
            const content = row.querySelector<HTMLElement>("[data-batch-height]")!;
            return {
              id: row.dataset.rowId,
              top: rect.top,
              bottom: rect.bottom,
              height: rect.height,
              expected: Number(content.dataset.batchHeight),
            };
          });
          return { trace, rows };
        }, version);
        const writes = result.trace.filter((entry) => entry.startsWith("write:"));
        expect(writes.length).toBe(version === 1 ? 12 : 11);
        const firstRead = result.trace.findIndex((entry) => entry.startsWith("read:"));
        expect(firstRead).toBeGreaterThanOrEqual(writes.length);
        expect(result.trace.slice(0, firstRead).filter((entry) => entry.startsWith("write:"))).toEqual(writes);
        expect(result.trace.some((entry) => entry.startsWith("stale:"))).toBe(false);
        expect(result.rows.length).toBe(writes.length);
        for (const [index, row] of result.rows.entries()) {
          expect(row.height).toBeCloseTo(row.expected, 1);
          if (index > 0) expect(row.top).toBeGreaterThanOrEqual(result.rows[index - 1]!.bottom - 0.5);
        }
        if (version === 2) {
          expect(result.rows.some((row) => row.id === "batch-0")).toBe(false);
          expect(result.trace).not.toContain("read:batch-0");
        }
      }
    } finally {
      await page.close();
    }
  });

  test("fast flings and uneven drags keep the view covered", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
    await page.waitForFunction(() => "__debug" in window);
    await page.evaluate(`window.__debug.seedRows(3000)`);
    const fling = (steps: number[], down = false) =>
      page.evaluate(`(${steppedFling.toString()})(${JSON.stringify({ steps, down })})`) as Promise<{
        frames: number;
        blank: number;
        blanks: string[];
        mountedViewports: number;
      }>;
    const repeat = (pattern: number[]) => Array.from({ length: 400 }, (_, frame) => pattern[frame % pattern.length]);
    // About the bench's capped fling (4-5 viewports a frame), with the few percent of frame-time
    // jitter a 60 fps frame callback has.
    const flinging = repeat([1, 1.06, 0.95, 1.09, 0.92, 1.03, 0.97, 1.08, 0.94].map((each) => 5 * each));
    // A scrollbar drag: pointer moves land unevenly against frames, 2 to 4 viewports apart and at
    // most twice the last move, which the lead two moves ahead covered before the fling fix.
    const dragging = repeat([3, 2, 4, 2.5, 3.5, 2, 3, 4]);
    // One fling warms the transcript's layout, as the bench's first fling does.
    await fling(flinging);
    const results = { up: await fling(flinging), down: await fling(flinging, true), drag: await fling(dragging) };
    console.log(`transcript-fling: ${JSON.stringify(results)}`);
    for (const result of Object.values(results)) {
      expect(result.frames).toBeGreaterThan(30);
      expect(result.blank / result.frames).toBeLessThanOrEqual(0.05);
    }
    // A fling builds the view and the views the next frames reach, not the rows it jumps over or a
    // warm window around a view the next frame has left (perf cron: 54 ms of React a fling frame):
    // the rows mounted a frame stay a few viewports however far a frame jumps (a god session's fling
    // moves tens of viewports a frame).
    const jumping = await fling(repeat([30, 31.5, 29, 30.5]));
    console.log(`transcript-fling jumping: ${JSON.stringify({ ...jumping, blanks: jumping.blanks.length })}`);
    expect(results.up.mountedViewports).toBeLessThanOrEqual(5);
    // Thirty viewports a frame is past what a frame's margin can predict: the view alone.
    expect(jumping.mountedViewports).toBeLessThanOrEqual(2.5);

    // A stopped fling should release its directional lead after the idle timeout. Without the
    // decay, the mounted range stays several viewports wider than the settled view indefinitely.
    // A jump far past the cap mounts the view alone (above); once the scroll's lead decays, the warm
    // rows held through the fling come back around the settled view, HISTORY_VIEWPORTS (4) above it
    // and a viewport below (Leo, 2026-11-12: "if you try to scroll up, you can't really scroll much of
    // anything up at all"), each reaching half a warm step further, and nothing wider stays.
    const mountedExtent = () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      return rows.reduce((sum, row) => sum + row.getBoundingClientRect().height, 0) / scroller.clientHeight;
    };
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.floor((scroller.scrollHeight - scroller.clientHeight) / 2);
      await window.cmuxPaintFrame();
    });
    await page.waitForFunction(`(${mountedExtent.toString()})() > 2.5`, undefined, { timeout: 2_000 });
    await page.evaluate(() => window.cmuxPaintFrame());
    const settled = await page.evaluate(`(${mountedExtent.toString()})()`);
    expect(settled as number).toBeLessThanOrEqual(7.5);
    await page.close();
  });
  // Leo, 2026-11-08: scrolling up and down quickly shows "hard cutoffs where there's no text at
  // all for a brief second". Each reversal moves the view back over rows it just passed.
  test("quick up-and-down scrolling keeps every painted viewport covered", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      await page.evaluate(`window.__debug.seedRows(3000)`);
      await page.locator(".acpmux-scroll").hover();
      await page.mouse.wheel(0, -100);
      await page.evaluate(async () => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        node.scrollTop = (node.scrollHeight - node.clientHeight) / 2;
        for (let frame = 0; frame < 12; frame += 1) await window.cmuxPaintFrame();
      });
      await page.evaluate(startScrollCoverage, { timeoutMs: 20_000 });
      // A trackpad shaken up and down: half to one and a half viewports a frame, turning every
      // few frames, each burst a little longer than the last.
      const steps = await page.evaluate(async () => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const sizes = [0.5, 0.9, 1.3, 1.5, 1.1, 0.7];
        let moved = 0;
        for (let turn = 0; turn < 16; turn += 1) {
          const sign = turn % 2 === 0 ? 1 : -1;
          for (let frame = 0; frame < 4 + (turn % 3); frame += 1) {
            const by = sizes[(turn + frame) % sizes.length]! * node.clientHeight * sign;
            await window.cmuxPaintFrame(() => {
              node.scrollTop += by;
            });
            moved += 1;
          }
        }
        await window.cmuxPaintFrame();
        return moved;
      });
      const result = await page.evaluate(() => window.__stopScrollCoverage!());
      console.log(`transcript-reversal: ${JSON.stringify({ steps, ...result })}`);
      expect(result.timed_out).toBe(false);
      expect(result.frames).toBeGreaterThan(30);
      expect(result.blank_frames).toBe(0);
    } finally {
      await page.close();
    }
  });
  for (const input of ["motion", "wheel"] as const) {
    test(`${input}: first movement from rest keeps every painted viewport covered`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      page.on("console", (message) => {
        if (message.type() === "error") errors.push(message.text());
      });
      try {
        await installPaintedFrames(page);
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
        await page.waitForFunction(() => "__debug" in window);
        await page.evaluate(`window.__debug.seedRows(3000)`);
        await page.locator(".acpmux-scroll").hover();
        // Real reader input releases follow before positioning the test in history.
        await page.mouse.wheel(0, -100);
        await page.evaluate(() => window.cmuxPaintFrame());
        const start = await page.evaluate(async () => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          node.scrollTop = (node.scrollHeight - node.clientHeight) / 2;
          const started = performance.now();
          return await new Promise<{ top: number; viewport: number }>((resolve, reject) => {
            let previous = "";
            let stable = 0;
            window.cmuxAfterPaint(() => {
              const extent = node.scrollHeight - node.clientHeight;
              const snapshot = `${node.scrollTop}/${extent}/${node.querySelectorAll(".acpmux-row").length}`;
              stable = snapshot === previous ? stable + 1 : 0;
              previous = snapshot;
              // The directional lead expires after 120 ms; begin with no warmed fling range.
              if (
                performance.now() - started >= 180 &&
                stable >= 3 &&
                node.scrollTop > extent * 0.4 &&
                node.scrollTop < extent * 0.6
              ) {
                resolve({ top: node.scrollTop, viewport: node.clientHeight });
                return false;
              }
              if (performance.now() - started > 5_000) {
                reject(new Error("first-motion fixture did not settle in history"));
                return false;
              }
            });
          });
        });
        await page.evaluate(startScrollCoverage, { timeoutMs: 10_000 });
        if (input === "motion") {
          // Exercise the product clock: a short large glide exceeds the idle warm range on
          // its first step. No synthetic scroll event and no first-frame exclusion.
          await page.evaluate(`(async () => {
            const { animateScrollBy } = await import("/src/agent-session/acpmux/threadMinimap/scrollMotion.ts");
            const node = document.querySelector(".acpmux-scroll");
            await new Promise(resolve => animateScrollBy(node, -24 * node.clientHeight, 160, [0, 0, 1, 1], false, resolve));
            await window.cmuxPaintFrame();
          })()`);
        } else {
          // Playwright sends real pixel wheel input through the browser's default scrolling.
          for (const viewports of [6, 6, 5, 4, 3, 2, 1, 0.5]) {
            await page.mouse.wheel(0, -viewports * start.viewport);
            await page.evaluate(() => window.cmuxPaintFrame());
          }
        }
        await page.evaluate(() => window.cmuxPaintFrame());
        const result = await page.evaluate(() => window.__stopScrollCoverage!());
        console.log(`transcript-first-${input}: ${JSON.stringify({ start, ...result })}`);
        expect(result.timed_out).toBe(false);
        expect(result.frames).toBeGreaterThan(0);
        expect(result.distance_px).toBeGreaterThan(start.viewport * 6);
        expect(result.blank_frames).toBe(0);
        expect(result.max_uncovered_px).toBeLessThanOrEqual(0.5);
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
