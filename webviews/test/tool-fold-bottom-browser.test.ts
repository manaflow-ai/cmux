// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Every open and close of a tool call at the bottom of a long transcript plays the fold (Leo,
// 2026-11-07: "i think the expansion of tool calls at the bottom of the transcript sometimes gets
// unreliable... sometimes it doesn't play ythe animation, and also, sometimes it lags when i open
// it"). Real Chromium opens and closes a command with a long log and an edit with a long diff
// (ToolFoldBottom.gallery.ts) at the very bottom: after the chat settled, while the reply streams in
// under them, and right after a send, the opens on a page slowed 2x (a slower or busy Mac). On every
// painted frame it reads the opened box's height: the fold must show at least two frames between
// closed and open, each way. TOOL_FOLD_FRAMES=1 prints every frame; TOOL_FOLD_COST=1 prints the
// open's cost (the before and after numbers).
//
// Real Chromium from Playwright on the agent pane's gallery scene.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("tool-fold-bottom-browser.test.ts", async () => {
  const ENTRY = "agent-pane.tool-fold-bottom";
  setDefaultTimeout(180_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("tool-fold-bottom: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "idle" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The call's line. A finished turn draws its opened "Worked for" rows under ids of their own
  /// (`fold-bottom-edit:fold`), so the row is matched by its id's start.
  const toggleOf = (row: string) => `[data-row-id^="${row}"] button.cv-tool.is-toggle[aria-expanded]`;

  /// Every finite animation over, then the scroller's offset and height the same over 12 painted frames.
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
      for (let frames = 0; frames < 240 && still < 12; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });

  /// Puts the view at its very end, as the reader's wheel does, and waits for it to hold still.
  const toEnd = async (page: Page) => {
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
      node.scrollTop = node.scrollHeight;
      node.dispatchEvent(new Event("scroll"));
    });
    await settled(page);
  };

  async function open(variant: string): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(".acpmux-row").first().waitFor();
    // The stage runs the variant's play (it opens the finished turn's "Worked for" line) only once
    // its DOM has held still, and marks itself ready after. Settling before then let that click land
    // after the wait: its rows slid in under the reader's click, the reply drawn over the edit line.
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    // The scene's play arms its hooks once the chat is drawn.
    const hook = { streaming: "cmuxGalleryStream", "after-send": "cmuxGallerySend" }[variant];
    if (hook)
      await page.waitForFunction(
        (name) => typeof (window as unknown as Record<string, unknown>)[name] === "function",
        hook,
        {
          timeout: 60_000,
        },
      );
    await settled(page);
    await toEnd(page);
    // Right after a send: the prompt goes out and its turn's calls come in, one frame paints, then
    // the reader clicks (`watchToggle`).
    if (variant === "after-send")
      await page.evaluate(async () => {
        window.cmuxGallerySend!();
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
      });
    await page.locator(toggleOf("fold-bottom-edit")).waitFor();
    return page;
  }

  type Frame = { at: number; height: number; open: string | null; fromEnd: number };

  /// Clicks `row`'s line and reads every painted frame for `ms`: the height of the row's opened box
  /// (`.cv-fold`, 0 when none is drawn). `drive` names a gallery hook run in each frame's callbacks
  /// (a streamed chunk) or once on the click's first frame (a send).
  const watchToggle = async (page: Page, row: string, drive?: { hook: string }, ms = 700) => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      const box = line.getBoundingClientRect();
      const x = box.left + Math.min(40, box.width / 2);
      // Its upper part: the next row's box may start a few pixels over the line's foot.
      const y = box.top + Math.min(7, box.height / 2);
      const hit = document.elementFromPoint(x, y);
      return { x, y, own: line.contains(hit), hit: hit?.closest(".acpmux-row")?.getAttribute("data-row-id") };
    }, toggleOf(row));
    expect({ row, own: point.own, hit: point.hit }).toEqual({ row, own: true, hit: point.hit });
    await page.evaluate(() => {
      const scope = window as unknown as { foldStart?: number };
      scope.foldStart = 0;
      addEventListener("click", () => (scope.foldStart = performance.now()), { capture: true, once: true });
    });
    const watching = page.evaluate(
      ({ duration, line, drive }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          const scope = window as unknown as { foldStart?: number } & Record<string, (() => void) | undefined>;
          let driven = 0;
          window.cmuxAfterPaint(
            () => {
              const start = scope.foldStart ?? 0;
              if (!start) return;
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const box = document
                .querySelector<HTMLElement>(line)!
                .closest(".acpmux-row")
                ?.querySelector<HTMLElement>(".cv-fold");
              frames.push({
                at: performance.now() - start,
                height: box ? box.getBoundingClientRect().height : 0,
                open: document.querySelector<HTMLElement>(line)!.getAttribute("aria-expanded"),
                fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              });
              if (performance.now() - start < duration) return;
              resolve(frames);
              return false;
            },
            () => {
              // A chunk every third frame: about 20 a second, as a reply streams in.
              if (!scope.foldStart || !drive || ++driven % 3 !== 0) return;
              scope[drive.hook]?.();
            },
          );
        }),
      { duration: ms, line: toggleOf(row), drive },
    );
    await page.mouse.click(point.x, point.y);
    return watching;
  };

  /// Frames drawn strictly between the start and end heights: the fold's own motion.
  const between = (frames: Frame[], from: number, to: number) => {
    const low = Math.min(from, to) + 1;
    const high = Math.max(from, to) - 1;
    return frames.filter((frame) => frame.height > low && frame.height < high).length;
  };

  const boxHeight = (page: Page, row: string) =>
    page.evaluate((line) => {
      const box = document
        .querySelector<HTMLElement>(line)
        ?.closest(".acpmux-row")
        ?.querySelector<HTMLElement>(".cv-fold");
      return box ? box.getBoundingClientRect().height : 0;
    }, toggleOf(row));

  /// The page's main thread slowed `rate` times (Chrome's CPU throttling), as on a slower or busy Mac.
  const slow = async (page: Page, rate: number) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate });
  };

  /// After the chat settled and right after a send, the open runs on a page twice as slow as this
  /// runner, as on a slower or busy Mac, where drawing a big call's body takes more than a frame: on
  /// base the fold counted that frame as load and landed at once. The close, and both while a reply
  /// streams (the page is busy already), run at full speed.
  const SCENES = [
    { variant: "idle", drive: undefined, rate: 2 },
    { variant: "streaming", drive: { hook: "cmuxGalleryStream" }, rate: 1 },
    { variant: "after-send", drive: undefined, rate: 2 },
  ] as const;

  const seen = (frames: Frame[]) =>
    frames.map((frame) => `${Math.round(frame.at)}:${Math.round(frame.height)}`).join(" ");

  for (const scene of SCENES)
    for (const row of ["fold-bottom-command", "fold-bottom-edit"])
      test(`at the very bottom (${scene.variant}), ${row} opens and closes with the fold`, async () => {
        const page = await open(scene.variant);
        await slow(page, scene.rate);
        const closed = await boxHeight(page, row);
        const opening = await watchToggle(page, row, scene.drive);
        await settled(page);
        const opened = await boxHeight(page, row);
        // After a send the view stays where the send put it; elsewhere it goes back to its very end.
        if (scene.variant !== "after-send") await toEnd(page);
        await slow(page, 1);
        const closing = await watchToggle(page, row, scene.drive);
        await settled(page);
        const shut = await boxHeight(page, row);
        if (process.env.TOOL_FOLD_FRAMES === "1")
          console.log(`tool-fold ${scene.variant} ${row}\n  open=${seen(opening)}\n  close=${seen(closing)}`);
        expect(opened).toBeGreaterThan(100);
        expect(shut).toBe(0);
        // At least two painted frames between closed and open, each way: the fold played.
        const scenario = { row, scene: scene.variant };
        expect({ ...scenario, opens: between(opening, closed, opened) >= 2, seen: seen(opening) }).toEqual({
          ...scenario,
          opens: true,
          seen: seen(opening),
        });
        expect({ ...scenario, closes: between(closing, opened, 0) >= 2, seen: seen(closing) }).toEqual({
          ...scenario,
          closes: true,
          seen: seen(closing),
        });
        await page.close();
      });

  // TOOL_FOLD_COST=1: the open's cost, the before and after numbers for a fix. Opens the command with
  // the 1,200-line log at the very bottom REPS times, at full speed and at half, and prints p50/p95
  // of the time from the click event to the first painted frame that shows it opening, and of the longest
  // gap between painted frames while it opens.
  test.skipIf(process.env.TOOL_FOLD_COST !== "1")("cost of opening a big call at the very bottom", async () => {
    const reps = Number(process.env.TOOL_FOLD_REPS ?? 10);
    const row = "fold-bottom-command";
    const pct = (values: number[], p: number) => {
      const sorted = [...values].sort((a, b) => a - b);
      return Math.round(sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!);
    };
    for (const rate of [1, 2]) {
      const firstMove: number[] = [];
      const longestGap: number[] = [];
      const played: number[] = [];
      for (let rep = 0; rep < reps; rep++) {
        const page = await open("idle");
        await slow(page, rate);
        const frames = await watchToggle(page, row, undefined, 500);
        const moved = frames.find((frame) => frame.height > 1);
        firstMove.push(moved?.at ?? 500);
        let gap = 0;
        for (let index = 1; index < frames.length; index++)
          gap = Math.max(gap, frames[index]!.at - frames[index - 1]!.at);
        longestGap.push(gap);
        const end = Math.max(...frames.map((frame) => frame.height));
        played.push(between(frames, 0, end));
        await page.close();
      }
      console.log(
        `tool-fold cost cpu=${rate}x reps=${reps} firstMove p50=${pct(firstMove, 50)} p95=${pct(firstMove, 95)} ms; longestGap p50=${pct(longestGap, 50)} p95=${pct(longestGap, 95)} ms; frames mid-fold p50=${pct(played, 50)} min=${Math.min(...played)}`,
      );
    }
  });
});
