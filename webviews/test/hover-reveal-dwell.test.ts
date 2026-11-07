// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// A hover control's opacity follows how long the pointer stays, never a fixed fade (Leo, 2026-11-07:
// "it should be, like, having its limit based off of how long you've had your cursor actually on
// it. So it doesn't necessarily act, like, oh, okay, you had it for a brief instant. It's going to
// play its full animation and go to full brightness and then just disappear"). In Chromium, on the
// gallery's chat (agent-pane.hover-dwell), with the real pointer:
// - a brush of 80 ms starts the ramp at once and peaks faint (under 0.4), then reverses to 0 with no
//   flash to full; a brush of 200 ms still stops short of full;
// - a pointer that stays brings the controls to full;
// - Tab into a row's controls shows them at full in the same frame;
// - Reduce Motion shows them at once;
// - nothing reveals them with a keyframe animation: each is an opacity transition, which reverses
//   from where it is.
// The page's animations run at a fiftieth of real time (DevTools' Animation.setPlaybackRate), so the
// pointer's timing, not the harness's latency, sets the dwell: 80 ms of animation is 4 s of wall
// time, and the pointer leaves once the row's own pointerenter is that long ago. Each case reports
// the dwell it measured from the row's pointerenter and pointerleave.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/hover-reveal-dwell.test.ts
// CMUX_HOVER_DWELL_CAPTURE_DIR=DIR also writes the brush-past as a strip of frames.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-reveal-dwell.test.ts", async () => {
  const ENTRY = "agent-pane.hover-dwell";
  /// A fiftieth of real time: a loaded host's input latency (a few hundred ms) is then a few ms of dwell.
  const RATE = 0.02;
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const captures = process.env.CMUX_HOVER_DWELL_CAPTURE_DIR;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "rest" } });
    if (captures) await mkdir(captures, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // The gallery frame answers prefers-reduced-motion from its own reducedMotion parameter (gallery/frame/media.ts).
  const open = async (reducedMotion = false) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(
      base +
        galleryFrame(ENTRY, { variant: "rest", width: 760, height: 560, reducedMotion: reducedMotion ? 1 : undefined }),
    );
    await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    await page.waitForSelector(".cv-user .cv-user__actions");
    // Park the pointer where no row is.
    await page.mouse.move(2, 2);
    return page;
  };

  const slowAnimations = async (page: Page) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Animation.enable");
    await cdp.send("Animation.setPlaybackRate", { playbackRate: RATE });
  };

  type Trace = { peak: number; last: number; samples: number[]; dwellMs: number; peakAt: number };

  /** Samples `control`'s opacity each frame while the pointer stays on `row` for `dwellMs` of animation time. */
  const brush = async (page: Page, row: string, control: string, index: number, dwellMs: number, strip?: string) => {
    await page.evaluate(
      ({ row, control, index }) => {
        const host = document.querySelectorAll(row)[index]!;
        const target = host.querySelector(control)!;
        const state = { samples: [] as number[], enter: 0, leave: 0, stop: false };
        host.addEventListener("pointerenter", () => (state.enter = performance.now()), { once: true });
        host.addEventListener("pointerleave", () => (state.leave = performance.now()), { once: true });
        // raf-read: the opacity frame by frame is the behavior under test; a computed opacity forces style, not layout.
        const tick = () => {
          state.samples.push(Number(getComputedStyle(target).opacity));
          // raf-read: one opacity sample per frame is the trace under test.
          if (!state.stop) requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        (window as unknown as { __dwell: typeof state }).__dwell = state;
      },
      { row, control, index },
    );
    await page.locator(row).nth(index).scrollIntoViewIfNeeded();
    const box = (await page.locator(row).nth(index).boundingBox())!;
    const shots: { png: Buffer; opacity: number }[] = [];
    // The row and the footer line under it, where a prompt's time and Copy sit.
    const frame = async () => {
      if (!strip) return;
      const png = await page.screenshot({ clip: { x: 0, y: box.y - 4, width: 760, height: box.height + 40 } });
      const opacity = await page.evaluate(
        ({ row, control, index }) =>
          Number(getComputedStyle(document.querySelectorAll(row)[index]!.querySelector(control)!).opacity),
        { row, control, index },
      );
      shots.push({ png, opacity });
    };
    await page.mouse.move(box.x + box.width / 2, box.y + Math.min(12, box.height / 2));
    const wall = dwellMs / RATE;
    const stayed = () =>
      page.evaluate((wall) => {
        const state = (window as unknown as { __dwell: { enter: number } }).__dwell;
        return state.enter > 0 && performance.now() - state.enter >= wall;
      }, wall - 30);
    while (!(await stayed())) if (strip) await frame();
    await page.mouse.move(2, 2);
    const settled = () =>
      page.evaluate(() => {
        const state = (window as unknown as { __dwell: { samples: number[]; leave: number } }).__dwell;
        return state.leave > 0 && state.samples.at(-1) === 0 && performance.now() - state.leave > 300;
      });
    if (strip) {
      const deadline = Date.now() + 20_000;
      while (!(await settled()) && Date.now() < deadline) await frame();
    } else
      await page.waitForFunction(
        () => {
          const state = (window as unknown as { __dwell: { samples: number[]; leave: number } }).__dwell;
          return state.leave > 0 && state.samples.at(-1) === 0 && state.samples.length > 3;
        },
        undefined,
        { timeout: 20_000 },
      );
    const trace: Trace = await page.evaluate((rate) => {
      const state = (
        window as unknown as { __dwell: { samples: number[]; enter: number; leave: number; stop: boolean } }
      ).__dwell;
      state.stop = true;
      const peak = Math.max(...state.samples);
      return {
        peak,
        peakAt: state.samples.indexOf(peak),
        last: state.samples.at(-1)!,
        samples: state.samples,
        dwellMs: (state.leave - state.enter) * rate,
      };
    }, RATE);
    if (strip && captures) {
      const { writeFile } = await import("node:fs/promises");
      const keep = [...new Set(Array.from({ length: 12 }, (_, i) => Math.round((i * (shots.length - 1)) / 11)))].map(
        (i) => shots[i]!,
      );
      await Promise.all(
        keep.map((shot, i) =>
          writeFile(
            path.join(captures, `${strip}-${String(i).padStart(2, "0")}-opacity-${shot.opacity.toFixed(2)}.png`),
            shot.png,
          ),
        ),
      );
    }
    return trace;
  };

  const ROWS = [
    { name: "a prompt's time and Copy", row: ".cv-user", control: ".cv-user__actions" },
    { name: "a reply's time", row: ".acpmux-turnSummary", control: ".cv-turn-time" },
  ];

  for (const { name, row, control } of ROWS) {
    test(`${name}: an 80 ms brush peaks faint and reverses, with no flash to full`, async () => {
      const page = await open();
      try {
        await slowAnimations(page);
        const trace = await brush(page, row, control, 1, 80, captures ? `brush-${row.replace(/\W/g, "")}` : undefined);
        const label = `dwell ${trace.dwellMs.toFixed(0)} ms, peak ${trace.peak.toFixed(3)}`;
        console.log(`${name}: ${label}`);
        expect(trace.dwellMs, label).toBeGreaterThan(50);
        expect(trace.dwellMs, label).toBeLessThan(130);
        // The ramp starts with the pointer (no delay that hides a pass entirely)…
        expect(trace.peak, label).toBeGreaterThan(0.05);
        // …and a pass reaches only a faint level.
        expect(trace.peak, label).toBeLessThan(0.4);
        // It reverses from its peak back to rest: after the peak, it only falls.
        const after = trace.samples.slice(trace.peakAt);
        for (let i = 1; i < after.length; i++) expect(after[i]!, label).toBeLessThanOrEqual(after[i - 1]! + 0.001);
        expect(trace.last, label).toBe(0);
      } finally {
        await page.close();
      }
    });
  }

  test("a 200 ms brush still stops short of full", async () => {
    const page = await open();
    try {
      await slowAnimations(page);
      const trace = await brush(
        page,
        ".cv-user",
        ".cv-user__actions",
        2,
        200,
        captures ? "brush200-cvuser" : undefined,
      );
      const label = `dwell ${trace.dwellMs.toFixed(0)} ms, peak ${trace.peak.toFixed(3)}`;
      console.log(`200 ms brush: ${label}`);
      expect(trace.dwellMs, label).toBeLessThan(260);
      expect(trace.peak, label).toBeGreaterThan(0.4);
      expect(trace.peak, label).toBeLessThan(0.95);
      expect(trace.last, label).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("a pointer that stays brings the controls to full", async () => {
    const page = await open();
    try {
      const box = (await page.locator(".cv-user").nth(1).boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + Math.min(12, box.height / 2));
      // The ramp is 400 ms; it settles on exactly 1.
      await page.waitForFunction(
        () => Number(getComputedStyle(document.querySelectorAll(".cv-user__actions")[1]!).opacity) === 1,
        undefined,
        { timeout: 5_000 },
      );
      expect(
        await page.evaluate(() => Number(getComputedStyle(document.querySelectorAll(".cv-user__actions")[1]!).opacity)),
      ).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("Tab into a row's controls shows them at full in the same frame", async () => {
    const page = await open();
    try {
      // Start from the prompt's own row, so Tab's next stop is its controls. Tabbing from the page start
      // goes through the composer, which takes focus back while the chat loads, so on a slow host 80
      // presses never left it.
      await page.locator("article.acpmux-user").first().focus();
      let reached = false;
      for (let i = 0; i < 20 && !reached; i++) {
        await page.keyboard.press("Tab");
        reached = await page.evaluate(() => Boolean(document.activeElement?.closest(".cv-user__actions")));
      }
      expect(reached).toBe(true);
      // Read at once: a fade, however short, would still be near 0 here.
      const opacity = await page.evaluate(() =>
        Number(getComputedStyle(document.activeElement!.closest(".cv-user__actions")!).opacity),
      );
      expect(opacity).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("Reduce Motion shows and hides them at once", async () => {
    const page = await open(true);
    try {
      const box = (await page.locator(".cv-user").nth(1).boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + Math.min(12, box.height / 2));
      // Under Reduce Motion the shared layer cuts every transition to 0.01 ms (pages/shared/desktop.css), so
      // the next frame shows the end state.
      const shown = await page.evaluate(
        () =>
          new Promise<number>((resolve) =>
            // raf-read: the first frame after the pointer arrives is the one that must already show it.
            requestAnimationFrame(() =>
              resolve(Number(getComputedStyle(document.querySelectorAll(".cv-user__actions")[1]!).opacity)),
            ),
          ),
      );
      expect(shown).toBeGreaterThan(0.99);
    } finally {
      await page.close();
    }
  });

  test("no hover control is revealed by a keyframe animation; each is an opacity transition", async () => {
    const page = await open();
    try {
      await slowAnimations(page);
      const box = (await page.locator(".cv-user").nth(1).boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + Math.min(12, box.height / 2));
      await page.waitForFunction(() =>
        document.getAnimations().some((animation) => {
          const target = (animation.effect as KeyframeEffect | null)?.target;
          return target instanceof Element && Boolean(target.closest(".cv-user__actions"));
        }),
      );
      const found = await page.evaluate(() => {
        const reveals = ".cv-user__actions, .cv-reply-actions, .cv-turn-actions, .cv-turn-time";
        return document.getAnimations().flatMap((animation) => {
          const target = (animation.effect as KeyframeEffect | null)?.target;
          if (!(target instanceof Element) || !target.closest(reveals)) return [];
          const kind =
            animation instanceof CSSTransition
              ? `transition:${animation.transitionProperty}`
              : animation instanceof CSSAnimation
                ? `keyframes:${animation.animationName}`
                : "script";
          return [kind];
        });
      });
      expect(found.length).toBeGreaterThan(0);
      expect(found.filter((kind) => kind !== "transition:opacity")).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
