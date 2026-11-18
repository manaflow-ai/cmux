// cmux-web-test-timeout: 400
// l10n-allow-file: the mock daemon's fixture turns, not shipped UI.
// A scroll frame that leaves the transcript's row window as it was renders nothing: no TranscriptView,
// no row. A frame that moves the window renders the rows entering it and nothing else of the rows.
// Scroll position is the transcript's state today (`setScroll`), so every scroll event renders
// TranscriptView and whatever under it the compiler did not keep; this file is the failing-first
// test for moving it out of render.
//
// The real pane (`?mock`), a chat of 300 heavy turns (`cmuxAcpmuxDebug.loadSeed`), parked three
// viewports up from the latest row (following is off, no older page is near) and left until its
// mounted rows hold still. Then the reader scrolls down one frame at a time: each animation frame a
// wheel event (the reader's input, userScroll.ts) and the offset moved by that much, so each frame
// fires one scroll event. Down, not up: on this base a small scroll up while the thread's sub-pixel
// origin is a quarter pixel is given back in part each frame (2 px a frame moves the view about
// 0.5 px, and every row's frame renders each frame), which would measure that rather than this.
// - "inside": 60 frames of 2 px. The mounted rows (`.acpmux-row[data-row-id]`) are the same every
//   frame, before and after; TranscriptView renders plus row renders must be 0.
// - "shift": 60 frames of 16 px (about 1.3 viewports). Rows enter the window; TranscriptView may
//   render about once per window change, rows already mounted not at all, and each entering row's
//   renders are bounded.
// Renders are read off each React commit the way React DevTools does: per component name
// (support/fiberRenders.ts) and per row element (support/commitRenders.ts, charging every component
// and host element that did work to the `.acpmux-row` it sits in).
// Real Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installRowRenderCounter, type RowRenderCount } from "./support/commitRenders";
import { installFiberRenders, startFiberRenders, stopFiberRenders } from "./support/fiberRenders";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type ScrollRun = {
  /// Scroll events the scroller fired over the run.
  scrolls: number;
  /// Mounted row ids before the first frame and after the last.
  before: string[];
  after: string[];
  /// Frames whose mounted rows differed from the frame before.
  windowChanges: number;
  /// Rows mounted at some frame of the run that were not mounted before it.
  entered: number;
  offsetMoved: number;
};

await requireBrowserLane("transcript-scroll-frame-renders.test.ts", async () => {
  setDefaultTimeout(380_000);
  const FRAMES = 60;
  /// Component names that are a transcript row or its content (VirtualTranscript.tsx drawRowFrames).
  const ROW_COMPONENTS = ["RowFrame", "RowContent"];
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  /// The pane with a long chat, parked about `viewports` up from the latest row and held still. The
  /// transcript's warm rows move in steps of half a viewport (VirtualTranscript.tsx WARM_STEP_VIEWPORTS,
  /// the offset rounded to a step), so the reader parks `past` px from the middle of a step: a scroll
  /// down of less than a quarter viewport less `past` leaves the warm rows where they were.
  async function openParked(browser: Browser, viewports: number, past: number): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await installFiberRenders(page);
    await page.addInitScript(installRowRenderCounter);
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.loadSeed(300))) as Record<string, any>;
    expect(seeded.error).toBeUndefined();
    const parked = await page.evaluate(
      async ([viewports, past]) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        // raf-read: it reads the mounted row ids and the offset, which React and the scroll set before the frame.
        const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
        const key = () =>
          [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
            .map((row) => row.dataset.rowId)
            .join(",");
        const step = scroller.clientHeight / 2;
        // Up in wheel-sized steps, as a reader would, so following turns off; then held still: the
        // same mounted rows and offset for 30 frames in a row (the scroll's lead decays and the
        // deferred warm rows land first).
        const moveTo = async (target: number) => {
          while (Math.abs(scroller.scrollTop - target) > 0.5) {
            const by = Math.max(-120, Math.min(120, target - scroller.scrollTop));
            scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: by, bubbles: true, cancelable: true }));
            const was = scroller.scrollTop;
            scroller.scrollTop += by;
            await frame();
            if (scroller.scrollTop === was) break;
          }
          let still = 0;
          let last = "";
          let lastTop = -1;
          for (let frames = 0; still < 30 && frames < 1200; frames += 1) {
            await frame();
            const now = key();
            still = now === last && scroller.scrollTop === lastTop ? still + 1 : 0;
            last = now;
            lastTop = scroller.scrollTop;
          }
          return still;
        };
        const target = () => Math.round((scroller.scrollTop - scroller.clientHeight * viewports) / step) * step + past;
        let still = await moveTo(target());
        // A row measured on the way may have moved the offset: once more, from where it is.
        const fine = Math.round(scroller.scrollTop / step) * step + past;
        if (Math.abs(scroller.scrollTop - fine) > 2) still = await moveTo(fine);
        return {
          still,
          top: scroller.scrollTop,
          fromStep: scroller.scrollTop - Math.round(scroller.scrollTop / step) * step,
          below: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
          height: scroller.clientHeight,
        };
      },
      [viewports, past] as const,
    );
    console.log(`SCROLL-FRAME parked ${JSON.stringify(parked)}`);
    expect(parked.still, "the parked transcript held still").toBe(30);
    expect(parked.top, "room above, so no older page loads").toBeGreaterThan(parked.height * 3);
    expect(parked.below, "room below to scroll down into").toBeGreaterThan(parked.height * 2);
    return page;
  }

  /// `frames` animation frames, each a wheel event and the offset moved `step` px, counted from the
  /// first frame until two frames after the last scroll event's commit.
  async function scrollFrames(page: Page, frames: number, step: number) {
    await page.evaluate(() => {
      (globalThis as any).__cmuxRowRenders.begin(document.querySelector(".acpmux-scroll"), ".acpmux-row");
    });
    await startFiberRenders(page);
    const run = (await page.evaluate(
      async ([frames, step]) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        // raf-read: one offset write a frame; the mounted row ids it reads are committed before the frame.
        const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
        const ids = () =>
          [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].map((row) => row.dataset.rowId!);
        let scrolls = 0;
        const onScroll = () => (scrolls += 1);
        scroller.addEventListener("scroll", onScroll, { passive: true });
        const before = ids();
        const seen = new Set(before);
        const entered = new Set<string>();
        let last = before.join(",");
        let windowChanges = 0;
        const startTop = scroller.scrollTop;
        const sample = () => {
          const now = ids();
          for (const id of now) if (!seen.has(id)) entered.add(id);
          const key = now.join(",");
          if (key !== last) windowChanges += 1;
          last = key;
        };
        for (let index = 0; index < frames; index += 1) {
          await frame();
          sample();
          scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: step, bubbles: true, cancelable: true }));
          scroller.scrollTop += step;
        }
        // The last offset's scroll event fires in the next frame; its commit lands by the one after.
        for (let index = 0; index < 2; index += 1) {
          await frame();
          sample();
        }
        scroller.removeEventListener("scroll", onScroll);
        return {
          scrolls,
          before,
          after: ids(),
          windowChanges,
          entered: entered.size,
          offsetMoved: scroller.scrollTop - startTop,
        };
      },
      [frames, step] as const,
    )) as ScrollRun;
    const fibers = await stopFiberRenders(page);
    const rows = (await page.evaluate(() => (globalThis as any).__cmuxRowRenders.end())) as RowRenderCount;
    const transcript = fibers.counts.TranscriptView ?? 0;
    const rowComponents = ROW_COMPONENTS.reduce((sum, name) => sum + (fibers.counts[name] ?? 0), 0);
    const perFrame = (value: number) => Math.round((value / frames) * 100) / 100;
    const top = Object.fromEntries(
      Object.entries(fibers.counts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 12)
        .map(([name, value]) => [name, perFrame(value)]),
    );
    return { run, fibers, rows, transcript, rowComponents, perFrame, top };
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`transcript-scroll-frame-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a scroll frame inside the row window renders no TranscriptView and no row", async () => {
        const page = await openParked(browser!, 3, -60);
        const { run, fibers, rows, transcript, rowComponents, perFrame, top } = await scrollFrames(page, FRAMES, 2);
        await page.close();
        console.log(
          `SCROLL-FRAME ${JSON.stringify({ engine: name, case: "inside", frames: FRAMES, scrolls: run.scrolls, moved: run.offsetMoved, mounted: run.before.length, window_changes: run.windowChanges, commits: fibers.commits, transcript_view: transcript, row_components: rowComponents, rows, per_frame: { transcript_view: perFrame(transcript), row_components: perFrame(rowComponents) }, top })}`,
        );
        // The run is what it says: every frame scrolled, and the window never moved.
        expect(run.scrolls).toBeGreaterThanOrEqual(FRAMES - 2);
        expect(Math.abs(run.offsetMoved - 2 * FRAMES), "offset moved by the frames' 2 px each").toBeLessThanOrEqual(2);
        expect(run.after, "the mounted rows after the scroll").toEqual(run.before);
        expect(run.windowChanges, "frames whose mounted rows changed").toBe(0);
        // Nothing rendered: TranscriptView, the row components, and anything inside a row element.
        expect(
          { transcriptView: transcript, rowComponents, rowsRendered: rows.rerendered + rows.added },
          "renders over 60 scroll frames inside the row window",
        ).toEqual({ transcriptView: 0, rowComponents: 0, rowsRendered: 0 });
      });

      test("a scroll frame that moves the row window renders only the rows entering", async () => {
        const page = await openParked(browser!, 3, 0);
        const { run, fibers, rows, transcript, rowComponents, perFrame, top } = await scrollFrames(page, FRAMES, 16);
        await page.close();
        console.log(
          `SCROLL-FRAME ${JSON.stringify({ engine: name, case: "shift", frames: FRAMES, scrolls: run.scrolls, moved: run.offsetMoved, mounted: run.before.length, window_changes: run.windowChanges, entered: run.entered, commits: fibers.commits, transcript_view: transcript, row_components: rowComponents, rows, per_frame: { transcript_view: perFrame(transcript), row_components: perFrame(rowComponents) }, top })}`,
        );
        expect(run.scrolls).toBeGreaterThanOrEqual(FRAMES - 2);
        // Rows measured as they mount may hold the reader's row and give back some of the offset.
        expect(run.offsetMoved).toBeGreaterThan(8 * FRAMES);
        // The window did move, by a few rows (not a jump that remounted it).
        expect(run.entered, "rows that entered the window").toBeGreaterThan(0);
        expect(run.windowChanges).toBeGreaterThan(0);
        expect(run.windowChanges).toBeLessThan(FRAMES / 2);
        // Generous bounds: TranscriptView about once per window change (a deferred render may add up
        // to two more each), not once per frame; rows that rendered, mounted before the scroll or
        // since, at most twice the rows that entered; RowFrame a few renders per entering row (its
        // mount, its measure).
        expect(transcript, "TranscriptView renders").toBeLessThanOrEqual(3 * run.windowChanges);
        expect(rows.rerendered + rows.added, "rows that rendered").toBeLessThanOrEqual(2 * run.entered);
        expect(fibers.counts.RowFrame ?? 0, "RowFrame renders").toBeLessThanOrEqual(3 * run.entered + 2);
      });
    });
  }
});
