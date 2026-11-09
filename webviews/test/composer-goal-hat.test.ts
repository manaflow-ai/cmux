// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// The chat's goal in the composer hat (TaskGoalStrip.tsx `GoalStrip`). Leo, 2026-11-09, on a
// reference goal pill: "that rapid click togle on/of fand its speed too... we need to study that!",
// "why they didnt have hover to see the goal?" and "no expansion of the goal in place either". The
// reference, frame-stepped (cmuxterm-hq docs/design/goal-ui-reference-study), opens in about
// 200 ms and closes in about 110 ms, takes clicks 68 ms apart, reverses each from where it is and
// never drops or queues one. This holds ours to that in real Chromium, on the gallery's frames
// (agent-pane.composer-goal), and prints the measured numbers:
// - a click paints its new state in the next frame (click to paint under 50 ms at p95);
// - fifteen clicks 60 ms apart each turn the fold around in the frame after the click, and the last
//   one wins with nothing still moving after its transition;
// - opening keeps the objective's first line where it was, and the composer where it was;
// - a resting pointer shows the whole goal in a hover card, and nothing in the stack moves.
//
// CI fails the file when it cannot launch a browser (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-goal-hat.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.composer-goal";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width = 760): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 420 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width, theme: "dark" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.locator(".acpmux-dock > .acpmux-goal[data-look]").waitFor({ timeout: 30_000 });
    await installPaintedFrames(page);
    return page;
  }

  /** Waits until the fold has no transition left to run. */
  const settled = (page: Page) =>
    page.waitForFunction(() => document.querySelector(".acpmux-goal-clip")!.getAnimations().length === 0, undefined, {
      timeout: 5_000,
    });

  /** Records, every frame, the fold's height and state, and every click's time, until `stop()`. */
  async function record(page: Page): Promise<void> {
    await page.evaluate(() => {
      const goal = document.querySelector<HTMLElement>(".acpmux-goal[data-look]")!;
      const clip = goal.querySelector<HTMLElement>(".acpmux-goal-clip")!;
      const log = { frames: [] as { t: number; h: number; open: boolean }[], clicks: [] as number[], on: true };
      (window as unknown as { goalLog: typeof log }).goalLog = log;
      goal.addEventListener("click", (event) => log.clicks.push(event.timeStamp), { capture: true });
      window.cmuxAfterPaint((t) => {
        log.frames.push({ t, h: clip.getBoundingClientRect().height, open: goal.hasAttribute("data-open") });
        return log.on;
      });
    });
  }
  type Log = { frames: { t: number; h: number; open: boolean }[]; clicks: number[] };
  const stop = (page: Page) =>
    page.evaluate(() => {
      const log = (window as unknown as { goalLog: Log & { on: boolean } }).goalLog;
      log.on = false;
      return { frames: log.frames, clicks: log.clicks } as Log;
    });

  const percentile = (values: number[], p: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
  };

  test("a click paints the new state in the next frame", async () => {
    const page = await open("with-hat");
    try {
      await record(page);
      const line = page.locator(".acpmux-goal-toggle");
      for (let click = 0; click < 20; click++) {
        await line.click();
        await settled(page);
      }
      const log = await stop(page);
      // Click to paint: the first frame after each click that shows the state it asked for.
      const latencies = log.clicks.map((at, index) => {
        const want = index % 2 === 0;
        const frame = log.frames.find((frame) => frame.t >= at && frame.open === want);
        return frame ? frame.t - at : Number.POSITIVE_INFINITY;
      });
      console.log(
        `goal toggle click to paint over ${latencies.length} clicks: p50 ${percentile(latencies, 50).toFixed(1)} ms, p95 ${percentile(latencies, 95).toFixed(1)} ms, max ${Math.max(...latencies).toFixed(1)} ms`,
      );
      // Open and close durations: from the click to the last frame whose height still changed.
      const durations = log.clicks.map((at, index) => {
        const until = log.clicks[index + 1] ?? Number.POSITIVE_INFINITY;
        const frames = log.frames.filter((frame) => frame.t >= at && frame.t < until);
        let last = at;
        for (let i = 1; i < frames.length; i++)
          if (Math.abs(frames[i]!.h - frames[i - 1]!.h) > 0.25) last = frames[i]!.t;
        return { open: index % 2 === 0, ms: last - at };
      });
      const opens = durations.filter((d) => d.open).map((d) => d.ms);
      const closes = durations.filter((d) => !d.open).map((d) => d.ms);
      console.log(
        `goal fold durations: open p50 ${percentile(opens, 50).toFixed(0)} ms, close p50 ${percentile(closes, 50).toFixed(0)} ms (reference: about 200 and 110)`,
      );
      expect(log.clicks.length).toBe(20);
      expect(percentile(latencies, 95)).toBeLessThan(50);
      expect(percentile(opens, 50)).toBeLessThan(260);
      expect(percentile(closes, 50)).toBeLessThan(170);
    } finally {
      await page.close();
    }
  });

  test("fifteen clicks 60 ms apart: each turns the fold around at once, none queues, the last wins", async () => {
    const page = await open("with-hat");
    try {
      await record(page);
      const box = (await page.locator(".acpmux-goal-toggle").boundingBox())!;
      // A point on the first line, left of the trailing buttons, so every click lands on the line.
      const x = box.x + 160;
      const y = box.y + 14;
      for (let click = 0; click < 15; click++) {
        await page.mouse.click(x, y);
        // fixed-wait: the click interval is what this measures (the reference took clicks 68 ms apart).
        await page.waitForTimeout(60);
      }
      await settled(page);
      await page.evaluate(() => window.cmuxPaintFrame());
      const log = await stop(page);
      expect(log.clicks.length).toBe(15);
      // Each click's next frame moves the height toward the state it asked for (no queued motion
      // finishing first). The first frame after a click can still be the old frame's value.
      const late: string[] = [];
      log.clicks.forEach((at, index) => {
        const want = index % 2 === 0;
        const after = log.frames.filter((frame) => frame.t > at).slice(0, 3);
        const moved = after.some(
          (frame, i) => i > 0 && (want ? frame.h > after[i - 1]!.h + 0.1 : frame.h < after[i - 1]!.h - 0.1),
        );
        if (!moved || after.find((frame) => frame.open !== want)) late.push(`click ${index + 1}`);
      });
      const last = log.frames.at(-1)!;
      const rest = log.frames.filter((frame) => frame.t > log.clicks.at(-1)! + 300);
      console.log(
        `goal rapid toggle: ${log.clicks.length} clicks, ${late.length} not reversed within two frames; final ${last.open ? "open" : "folded"} at ${last.h.toFixed(1)} px`,
      );
      expect(late).toEqual([]);
      expect(last.open).toBe(true);
      // Review of cmux#39151, F1: a fold that reversed still settles: open ends on `auto` height.
      expect(await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-goal-clip")!.style.height)).toBe(
        "auto",
      );
      // One more click mid-open, then one back: it ends folded, one cut line again (its ellipsis
      // and hover card come back).
      await page.mouse.click(x, y);
      // fixed-wait: the reversal must land while the open transition still runs.
      await page.waitForTimeout(40);
      await page.mouse.click(x, y);
      // fixed-wait: and this close is reversed mid-way too, then left to finish folded.
      await page.waitForTimeout(40);
      await page.mouse.click(x, y);
      await settled(page);
      const end = await page.evaluate(() => {
        const goal = document.querySelector<HTMLElement>(".acpmux-goal[data-look]")!;
        return {
          clamped: goal.hasAttribute("data-clamped"),
          height: goal.querySelector<HTMLElement>(".acpmux-goal-clip")!.style.height,
        };
      });
      expect(end).toEqual({ clamped: true, height: "" });
      expect(new Set(rest.map((frame) => frame.h.toFixed(1))).size).toBeLessThanOrEqual(1);
    } finally {
      await page.close();
    }
  });

  test("opening keeps the objective's first line and the composer in place", async () => {
    for (const width of [420, 760, 1100]) {
      const page = await open("with-hat", width);
      try {
        const measure = () =>
          page.evaluate(() => {
            const text = document.querySelector(".acpmux-goal-objective")!;
            const range = document.createRange();
            range.selectNodeContents(text);
            const first = range.getClientRects()[0]!;
            const composer = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
            return { left: first.left, bottom: first.bottom, composerTop: composer.top };
          });
        const before = await measure();
        // Open from the section's own top, so the first line stays in the viewport's terms.
        const top = await page.evaluate(() => document.querySelector(".acpmux-goal")!.getBoundingClientRect().top);
        await page.locator(".acpmux-goal-toggle").click();
        await settled(page);
        const after = await measure();
        const topAfter = await page.evaluate(() => document.querySelector(".acpmux-goal")!.getBoundingClientRect().top);
        // The card grows upward: the first line moves with the card's top, nothing else does.
        expect(Math.abs(after.left - before.left)).toBeLessThan(0.5);
        expect(Math.abs(after.bottom - topAfter - (before.bottom - top))).toBeLessThan(0.5);
        expect(Math.abs(after.composerTop - before.composerTop)).toBeLessThan(0.5);
      } finally {
        await page.close();
      }
    }
  });

  test("a long goal opened in a short pane scrolls inside the card, its end in reach", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 300 } });
    try {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "editing", width: 420, theme: "dark" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      await page.locator(".acpmux-goal-field").waitFor({ timeout: 30_000 });
      await settled(page);
      const save = page.getByRole("button", { name: "Save" });
      await save.scrollIntoViewIfNeeded();
      const inView = await save.evaluate((node) => {
        const r = node.getBoundingClientRect();
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        return hit === node || node.contains(hit);
      });
      expect(inView).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("a resting pointer shows the whole goal, and nothing in the stack moves", async () => {
    const page = await open("with-hat");
    try {
      const rects = () =>
        page.evaluate(() =>
          [".acpmux-goal", ".acpmux-running-tray", ".acpmux-composer-box"].map((selector) => {
            const r = document.querySelector(selector)!.getBoundingClientRect();
            return [r.top, r.left, r.width, r.height].map((n) => n.toFixed(1)).join(",");
          }),
        );
      const before = await rects();
      await page.locator(".acpmux-goal-toggle").hover({ position: { x: 200, y: 14 } });
      const preview = page.locator(".acpmux-goal-preview");
      await preview.waitFor({ timeout: 5_000 });
      const text = await preview.textContent();
      expect(text).toContain("stop when the queue is empty");
      expect(text).toContain("Updated 4 min. ago");
      expect(await rects()).toEqual(before);
    } finally {
      await page.close();
    }
  });
});
