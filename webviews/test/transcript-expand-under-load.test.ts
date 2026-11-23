// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a tool group at the very bottom of a running turn while the agent goes on (Leo,
// 2026-11-06, on a recording under heavy load: "the entire tool call expansion apparatus is borked",
// "way too discontinuous"). In his recording a row opened while the list reflowed under it, rows
// regrouped mid-motion and the view jumped. An ended stretch's run stays open while the chat works,
// so the reader has shut it (ExpandAtBottom.gallery.ts "under-load"); a stretch still running draws
// no run under the live-turn-work `line`. Here the agent's next command lands on the live
// line on the fold's third frame, with frames coming steadily and with the main thread held in every frame. An open at
// the very bottom grows down (Lucas, 2026-11-06; transcript-expand-at-bottom.test.ts),
// so on every painted frame the clicked line and the view's offset stay on their pixels, no row is
// drawn over the next and the opened row only grows. Under load the fold still ends in bounded time.
//
// Real Chromium from Playwright on the agent pane's gallery scene (ExpandAtBottom.gallery.ts,
// variant "under-load").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { FOLD_DROP_MS } from "../src/agent-session/acpmux/conversation/fold";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-expand-under-load.test.ts", async () => {
  const ENTRY = "agent-pane.expand-at-bottom";
  const VARIANT = "under-load";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("transcript-expand-under-load: skipping (run `bunx playwright install chromium`)");
    return;
  }
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ROW = '[data-row-id="expand-at-bottom-run"]';
  /// The run's own line: its calls are toggles too, drawn while a running turn's run is open.
  const GROUP = `${ROW} button.cv-tool.is-toggle[aria-expanded][data-tool-group]`;

  /// Every finite animation over, then the scroller's offset and height the same over 16 painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 16; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.locator(GROUP).waitFor();
    await page.waitForFunction(() => typeof window.cmuxGalleryArrive === "function", undefined, {
      timeout: 60_000,
    });
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    return page;
  }

  type Frame = {
    at: number;
    line: number;
    height: number;
    scrollTop: number;
    fromEnd: number;
    overlap: number;
    open: string | null;
    /// The opened row's fold is mid-flight on this frame (its body clipped, `data-fold-clip`).
    folding: boolean;
  };

  /// Clicks the group's line and reads every painted frame for `ms`; `cmuxGalleryArrive` runs in the
  /// callbacks of the fold's third frame, so the next snapshot lands mid-fold.
  const watchOpen = async (page: Page, ms = 900) => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      line.dataset.underLoadProbe = "";
      const box = line.getBoundingClientRect();
      const x = box.left + Math.min(40, box.width / 2);
      const y = box.top + box.height / 2;
      return { x, y, own: line.contains(document.elementFromPoint(x, y)) };
    }, GROUP);
    expect(point.own).toBe(true);
    // Armed before the click, in its own round trip: a listener added by the watch below could land
    // after a throttled page has already taken the click, and the watch would never start.
    await page.evaluate(() => {
      const scope = window as unknown as { underLoadStart?: number };
      scope.underLoadStart = 0;
      addEventListener("pointerdown", () => (scope.underLoadStart = performance.now()), {
        capture: true,
        once: true,
      });
    });
    const watching = page.evaluate(
      ({ duration, row }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          const scope = window as unknown as { underLoadStart?: number };
          let clicked = 0;
          /// A row's drawn foot: its box, less what a clip cuts off its bottom.
          const foot = (node: HTMLElement) => {
            const cut = /inset\(\S+ \S+ ([\d.]+)px/.exec(getComputedStyle(node).clipPath);
            return node.getBoundingClientRect().bottom - (cut ? Number(cut[1]) : 0);
          };
          window.cmuxAfterPaint(
            () => {
              const start = scope.underLoadStart ?? 0;
              if (!start) return;
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const line = document.querySelector<HTMLElement>("[data-under-load-probe]")!;
              const opened = document.querySelector<HTMLElement>(row)!;
              const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
                .filter((each) => each.getBoundingClientRect().height > 0)
                .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
              let overlap = 0;
              for (let index = 1; index < rows.length; index++)
                overlap = Math.max(overlap, foot(rows[index - 1]!) - rows[index]!.getBoundingClientRect().top);
              frames.push({
                at: performance.now() - start,
                line: line.getBoundingClientRect().top,
                height: foot(opened) - opened.getBoundingClientRect().top,
                scrollTop: scroller.scrollTop,
                fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
                overlap,
                open: line.getAttribute("aria-expanded"),
                folding: opened.querySelector("[data-fold-clip]") !== null,
              });
              if (performance.now() - start < duration) return;
              resolve(frames);
              return false;
            },
            () => {
              if (!scope.underLoadStart) return;
              clicked += 1;
              if (clicked === 3) window.cmuxGalleryArrive!();
            },
          );
        }),
      { duration: ms, row: ROW },
    );
    await page.mouse.click(point.x, point.y);
    return watching;
  };

  /// Holds the main thread JANK_MS in every frame's callbacks, as a page under heavy load does: no
  /// frame comes sooner than that after the one before. A frame's time is the display tick it started
  /// on, not when its callbacks ran, so two frames' times can lie up to two ticks closer than the hold
  /// (a 60 ms hold can leave them about 44 ms apart, under the fold's drop threshold, so the fold
  /// plays a second frame). Held this long, every gap is a dropped frame on any runner.
  const JANK_MS = FOLD_DROP_MS + 50;
  const jank = (page: Page, on: boolean) =>
    page.evaluate(
      ({ on, ms }) => {
        const scope = window as unknown as { stopJank?: () => void };
        scope.stopJank?.();
        if (!on) return;
        let running = true;
        const hold = () => {
          if (!running) return;
          const until = performance.now() + ms;
          while (performance.now() < until) {}
          // raf-read: none; this only holds the main thread in each frame's callbacks (the load).
          requestAnimationFrame(hold);
        };
        // raf-read: as above.
        requestAnimationFrame(hold);
        scope.stopJank = () => (running = false);
      },
      { on, ms: JANK_MS },
    );

  for (const load of ["light", "jank"] as const)
    test(`at the very bottom (${load}), a group opened while a command joins it is one motion`, async () => {
      const page = await open();
      const before = await page.evaluate(
        ({ selector, row }) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const opened = document.querySelector<HTMLElement>(row)!;
          return {
            line: document.querySelector<HTMLElement>(selector)!.getBoundingClientRect().top,
            height: opened.getBoundingClientRect().height,
            scrollTop: scroller.scrollTop,
            fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
          };
        },
        { selector: GROUP, row: ROW },
      );
      expect(before.fromEnd).toBeLessThanOrEqual(2);
      if (load === "jank") await jank(page, true);
      const frames = await watchOpen(page, load === "light" ? 900 : 1500);
      await jank(page, false);
      await settled(page);
      // UNDER_LOAD_FRAMES=1 prints every painted frame: the before and after numbers for a fix.
      if (process.env.UNDER_LOAD_FRAMES === "1")
        console.log(`under-load ${load} before=${JSON.stringify(before)} frames=${JSON.stringify(frames)}`);
      expect(frames.length).toBeGreaterThan(3);
      let height = before.height;
      for (const [index, frame] of frames.entries()) {
        const at = { load, index, ...frame };
        expect({ at, held: Math.abs(frame.line - before.line) <= 1 }).toEqual({ at, held: true });
        expect({ at, still: Math.abs(frame.scrollTop - before.scrollTop) <= 1 }).toEqual({ at, still: true });
        expect({ at, overlap: frame.overlap <= 1 }).toEqual({ at, overlap: true });
        expect({ at, grows: frame.height >= height - 0.5 }).toEqual({ at, grows: true });
        height = frame.height;
      }
      const after = await page.evaluate(
        (row) => ({
          commands: document.querySelectorAll(`${row} .cv-fold button.cv-tool`).length,
          label:
            document.querySelector<HTMLElement>(`${row} button.cv-tool.is-toggle[data-tool-group]`)?.textContent ?? "",
        }),
        ROW,
      );
      expect(after.label).toMatch(/2/);
      expect(after.commands).toBeGreaterThanOrEqual(2);
      // The next command reads on the live line, never as a row of the opened run.
      expect(
        await page.evaluate(() =>
          document.querySelector('[data-row-id="thinking-live"]')?.textContent?.includes("slow"),
        ),
      ).toBe(true);
      // Bounded: with frames coming steadily, the opened row stops growing within the fold's time and
      // a few frames. Under jank the next command lands when the page gets to it, so there the
      // bound is the one-step rule below.
      if (load === "light") {
        const last = frames.at(-1)!;
        // The webviews lib target predates Array.prototype.findLast: the last frame whose height changed.
        const lastChange = frames
          .filter((frame, index) => index > 0 && Math.abs(frame.height - frames[index - 1]!.height) > 0.5)
          .at(-1);
        expect({ load, settledAt: (lastChange ?? last).at <= 700 }).toEqual({
          load,
          settledAt: true,
        });
      }
      // Leo, 2026-11-06: "way too discontinuous". With frames dropping, the fold lands in one step,
      // never a run of partial heights a frame apart. One late frame is not load (Leo, 2026-11-07:
      // "sometimes it doesn't play ythe animation"), so it lands on the second in a row: at most two
      // painted frames show it mid-flight, the fold's first and the one its restarted clock draws
      // (fold.ts `settleOnDroppedFrames`), both near its start.
      if (load === "jank") {
        const midFlight = frames.filter((frame) => frame.folding).length;
        // The painted frames' times, `*` where the fold is mid-flight: a slow page or a missed drop.
        const seen = frames.map((frame) => `${Math.round(frame.at)}${frame.folding ? "*" : ""}`).join(" ");
        expect({ load, midFlight, seen, oneStep: midFlight <= 2 }).toEqual({ load, midFlight, seen, oneStep: true });
      }
      await page.close();
    });
});
