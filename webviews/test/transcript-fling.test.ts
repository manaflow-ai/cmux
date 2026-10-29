// A fast fling down a long chat keeps rows under the view (cx-j33s4). The frame pacing bench's
// fling (debug.ts startFling: 5000 rows, bottom to top in 3 s) left part of the view empty on
// 97-104 of 181 frames at the capped render rate: one frame there scrolls about as far as the
// transcript mounted ahead of the reader (App.tsx), so the next frame's view fell past it.
//
// Real WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
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
    return { frames, blank, blanks };
  };

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
    await page.close();
  });
});
