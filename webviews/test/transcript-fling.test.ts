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
import type { PromptMeasureApi } from "./browser/transcript-fling.harness";

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

  test("prompt reads batch after sibling writes and corrections place rows before paint", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 }, reducedMotion: "reduce" });
    type Snapshot = ReturnType<PromptMeasureApi["snapshot"]>;
    const placed = (snapshot: Snapshot) => {
      expect(snapshot.rows.map((row) => row.id)).toEqual([
        "prompt-wrap-0",
        "prompt-wrap-1",
        "prompt-label",
        "prompt-sentinel",
      ]);
      for (const [index, row] of snapshot.rows.entries()) {
        expect(row.height).toBeGreaterThan(0);
        // An overlap-only assertion misses a stale, too-tall estimate after unclamping.
        if (index > 0)
          expect(Math.abs(row.top - snapshot.rows[index - 1]!.bottom - snapshot.gap)).toBeLessThanOrEqual(1);
      }
    };
    const unchanged = (first: Snapshot, next: Snapshot) => {
      placed(first);
      placed(next);
      for (const [index, row] of first.rows.entries()) {
        expect(Math.abs(row.top - next.rows[index]!.top)).toBeLessThanOrEqual(1);
        expect(Math.abs(row.height - next.rows[index]!.height)).toBeLessThanOrEqual(1);
      }
    };
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__promptMeasure" in window);
      await page.addStyleTag({
        content: `
        .acpmux-row.acpmux-prompt-measure,.acpmux-row.acpmux-prompt-sentinel{min-height:0;padding:0}
        [data-prompt-measure].cv-user__bubble{max-width:none;padding:0;font:20px/20px monospace;letter-spacing:0;--cv-line-height:20px}
        [data-prompt-sentinel]{height:20px}
      `,
      });
      await page.evaluate(async () => {
        document.documentElement.dataset.agentMotion = "off";
        await document.fonts.ready;
      });
      const mount = await page.evaluate(async () => {
        const probe = window.__promptMeasure;
        probe.startTrace();
        await window.cmuxPaintFrame(() => probe.mount());
        const trace = probe.finishTrace();
        const first = probe.snapshot();
        await window.cmuxPaintFrame();
        return { ...trace, first, next: probe.snapshot() };
      });
      const writes = mount.trace.filter((entry) => entry.startsWith("write:"));
      expect(writes).toEqual(["write:prompt-wrap-0", "write:prompt-wrap-1", "write:prompt-label"]);
      const firstRead = mount.trace.findIndex((entry) => entry.startsWith("prompt:"));
      expect(firstRead).toBeGreaterThanOrEqual(writes.length);
      expect(mount.trace.slice(0, firstRead)).toEqual(writes);
      expect(mount.first.rows.slice(0, 3).map((row) => [row.clamped, row.toggle])).toEqual([
        [true, "false"],
        [true, "false"],
        [false, null],
      ]);
      unchanged(mount.first, mount.next);

      // A child-only content commit has no ancestor effect to drain its queued measurement.
      // Read after one microtask, before the rendering step/ResizeObserver can rescue it.
      for (const compact of [true, false]) {
        const change = await page.evaluate(async (short) => {
          const probe = window.__promptMeasure;
          probe.startTrace();
          const immediate = probe.compact(short);
          await Promise.resolve();
          const microtask = probe.finishTrace();
          const clampedBeforePaint = document
            .querySelector('[data-prompt-measure="prompt-wrap-0"] .cv-user__text')!
            .classList.contains("is-clamped");
          await window.cmuxPaintFrame();
          const first = probe.snapshot();
          await window.cmuxPaintFrame();
          return { immediate, microtask, clampedBeforePaint, first, next: probe.snapshot() };
        }, compact);
        expect(change.immediate.parentRenders).toBe(mount.parentRenders);
        expect(change.immediate.immediateReads).toBe(0);
        expect(change.microtask.trace.length).toBeGreaterThan(0);
        expect(change.microtask.trace.every((entry) => entry === "prompt:prompt-wrap-0")).toBe(true);
        expect(change.clampedBeforePaint).toBe(!compact);
        expect(change.first.rows[0]!.clamped).toBe(!compact);
        expect(change.first.rows[0]!.toggle).toBe(compact ? null : "false");
        unchanged(change.first, change.next);
      }

      const idle = await page.evaluate(async () => {
        const probe = window.__promptMeasure;
        probe.startTrace();
        await window.cmuxPaintFrame(() => probe.rerender());
        return probe.finishTrace();
      });
      expect(idle.parentRenders).toBeGreaterThan(mount.parentRenders);
      expect(idle.trace).toEqual([]);
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

    // A stopped fling should release its directional lead after the idle timeout. Without the
    // decay, the mounted range stays several viewports wider than the settled view indefinitely.
    const movingMounted = await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.floor((scroller.scrollHeight - scroller.clientHeight) / 2);
      await window.cmuxPaintFrame();
      return document.querySelectorAll<HTMLElement>(".acpmux-row").length;
    });
    await page.waitForFunction((count) => document.querySelectorAll(".acpmux-row").length < count, movingMounted, {
      timeout: 2_000,
    });
    await page.evaluate(() => window.cmuxPaintFrame());
    const settledMounted = await page.evaluate(() => document.querySelectorAll<HTMLElement>(".acpmux-row").length);
    expect(settledMounted).toBeLessThan(movingMounted);
    await page.close();
  });
});
