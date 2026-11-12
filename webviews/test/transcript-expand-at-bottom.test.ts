// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a line with the transcript at its very bottom grows down, as Codex opens a call at the end
// of a chat (Lucas, 2026-11-06, Codex parity; it replaces the bottom pin on open, Leo 2026-11-02): the
// line and the text above it stay on their pixels, what opens goes under the composer, and the view
// stops following. Anywhere else the line stays put and its body grows down too (#28780). Closing at
// the very bottom still pins it: the text above comes down and no blank room is left (Leo, 2026-11-03).
//
// Real Chromium from Playwright on the agent pane's gallery scene (ExpandAtBottom.gallery.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { installPaintedFrames } from "./support/paintedFrames";
import { pinArms } from "./support/pinArms";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-expand-at-bottom.test.ts", async () => {
  const ENTRY = "agent-pane.expand-at-bottom";
  const VARIANT = "shipped";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("transcript-expand-at-bottom: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "prompt" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The last turn's "Ran 2 commands" line.
  const GROUP = '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded]';
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
  /// Where things are drawn: the group's line, the last row's foot, and the scroller.
  const measure = (page: Page) =>
    page.evaluate((query) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      return {
        line: document.querySelector<HTMLElement>(query)!.getBoundingClientRect().top,
        lastFoot: rows.at(-1)!.getBoundingClientRect().bottom,
        scrollTop: scroller.scrollTop,
        scrollHeight: scroller.scrollHeight,
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        open: document.querySelector<HTMLElement>(query)!.getAttribute("aria-expanded"),
      };
    }, GROUP);

  /// Clicks the middle of `query`'s line with the mouse (a locator's click scrolls a line the
  /// composer covers into view first), after checking the point is the line's own.
  const clickLine = async (page: Page, query: string) => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      const box = line.getBoundingClientRect();
      const x = box.left + Math.min(40, box.width / 2);
      const y = box.top + box.height / 2;
      return { x, y, own: line.contains(document.elementFromPoint(x, y)) };
    }, query);
    expect(point.own).toBe(true);
    await page.mouse.click(point.x, point.y);
  };

  async function open(
    variant = VARIANT,
    ready = GROUP,
    engine: Browser = browser!,
    arms: Readonly<Record<string, string>> = {},
  ): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await engine.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await pinArms(page, arms);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(ready).waitFor();
    await settled(page);
    return page;
  }

  test("at the very bottom, opening a line keeps it on its pixel and grows its body down", async () => {
    const page = await open();
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    const before = await measure(page);
    expect(before.open).toBe("false");
    expect(before.fromEnd).toBeLessThanOrEqual(2);
    await clickLine(page, GROUP);
    await settled(page);
    const after = await measure(page);
    expect(after.open).toBe("true");
    // The line and the view stayed; what opened grew the chat down, past the view's end.
    expect(Math.abs(after.line - before.line)).toBeLessThanOrEqual(1);
    expect(Math.abs(after.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(after.fromEnd).toBeGreaterThan(40);
    await page.close();
  });

  // A long prompt's Show more at the very bottom opens as an open does anywhere in the chat (Codex
  // parity): the prompt's row and the view stay where they were, the text it shows grows down and
  // the reply under it moves down under the composer.
  test("at the very bottom, a long prompt's Show more opens it downward", async () => {
    const MORE = '.cv-user__more[aria-expanded="false"]';
    const page = await open("prompt", MORE);
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    const where = () =>
      page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const bubbles = [...scroller.querySelectorAll<HTMLElement>(".cv-user__text")];
        return {
          prompt: bubbles.at(-1)!.closest(".acpmux-row")!.getBoundingClientRect().top,
          lastFoot: rows.at(-1)!.getBoundingClientRect().bottom,
          scrollHeight: scroller.scrollHeight,
          fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        };
      });
    const before = await where();
    expect(before.fromEnd).toBeLessThanOrEqual(2);
    await clickLine(page, MORE);
    await page.locator('.cv-user__more[aria-expanded="true"]').waitFor();
    await settled(page);
    const after = await where();
    console.log(`prompt Show more: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
    expect(Math.abs(after.prompt - before.prompt)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(after.lastFoot - before.lastFoot).toBeGreaterThan(40);
    expect(after.fromEnd).toBeGreaterThan(40);
    await page.close();
  });

  /// Clicks `query` (unless `click` is false) and reads every painted frame for `ms`: `query`'s own
  /// top (`control`), the opened row's top (a Show more under its text stays at the row's foot, the text above it rises), the first row
  /// under it and the last row's foot, how far the view is from its end, and how far below the row
  /// under it the opened row is drawn (its foot less its clip).
  type Frame = { line: number; control: number; under: number; last: number; fromEnd: number; over: number };
  const watchOpen = async (page: Page, query: string, ms = 700, click = true) => {
    const watching = page.evaluate(
      ({ selector, duration }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          const start = performance.now();
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const line = document.querySelector<HTMLElement>(selector)!;
            const row = line.closest<HTMLElement>(".acpmux-row")!;
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
            const box = row.getBoundingClientRect();
            const next = rows
              .filter((each) => each !== row && each.getBoundingClientRect().top >= box.top + 1)
              .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0]!;
            const cut = /inset\(\S+ \S+ ([\d.]+)px/.exec(getComputedStyle(row).clipPath);
            frames.push({
              line: box.top,
              control: line.getBoundingClientRect().top,
              under: next.getBoundingClientRect().top,
              last: rows.at(-1)!.getBoundingClientRect().bottom,
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              over: box.bottom - (cut ? Number(cut[1]) : 0) - next.getBoundingClientRect().top,
            });
            if (performance.now() - start < duration) return;
            resolve(frames);
            return false;
          });
        }),
      { selector: query, duration: ms },
    );
    if (click) await clickLine(page, query);
    return watching;
  };

  /// Not only where it settles: on every frame of the fold the opened line keeps its pixel, the rows
  /// under it only move down, and nothing of what opened draws over the row under it (Codex parity).
  for (const [variant, query] of [
    [VARIANT, GROUP],
    ["prompt", '.cv-user__more[aria-expanded="false"]'],
  ] as const) {
    test(`at the very bottom (${variant}), every frame keeps the line still and grows down`, async () => {
      const page = await open(variant, query);
      await page.locator(".acpmux-scroll").evaluate((node, selector) => {
        node.querySelector<HTMLElement>(selector)!.dataset.openProbe = "true";
        node.scrollTop = node.scrollHeight;
      }, query);
      await settled(page);
      const PROBE = "[data-open-probe]";
      const before = (await watchOpen(page, PROBE, 0, false))[0]!;
      const frames = await watchOpen(page, PROBE);
      expect(frames.length).toBeGreaterThan(5);
      let under = before.under;
      for (const [index, frame] of frames.entries()) {
        const at = { index, ...frame };
        expect({ at, still: Math.abs(frame.line - before.line) <= 1 }).toEqual({ at, still: true });
        expect({ at, covered: frame.over <= 1 }).toEqual({ at, covered: true });
        expect({ at, down: frame.under >= under - 0.5 }).toEqual({ at, down: true });
        under = frame.under;
      }
      expect(frames.at(-1)!.under - before.under).toBeGreaterThan(40);
      await page.close();
    });
  }

  /// Leo, 2026-11-04: "how come there aren't animatiosn for expanding/collapsing tool calls
  /// anymore???". Opening "Ran 2 commands" at the very bottom glides the rows under it down while the
  /// line stays; back at the very end, closing it glides the text above down (the bottom pin), while
  /// the view stays at its end and the last row keeps its pixels. Each moves over several painted
  /// frames, never most of the way in one.
  // In Chromium and in WebKit, the app's own engine (where the thread slide this replaced jumped).
  for (const engineName of ["chromium", "webkit"] as const)
    test(`inline run at the very bottom (${engineName}), opening and closing a group glide the text above over several frames`, async () => {
      let engine = browser!;
      if (engineName === "webkit") {
        try {
          engine = await webkit.launch({ headless: true });
        } catch (error) {
          if (process.env.GITHUB_ACTIONS === "true") throw error;
          console.warn("transcript-expand-at-bottom: WebKit glide skipped (run `bunx playwright install webkit`)");
          return;
        }
        await warmGalleryFrame(vite!, ENTRY, { browser: engine, params: { variant: VARIANT } });
      }
      // This oracle measures the transcript's full inline expansion; boxed runs own their scroll.
      const page = await open(VARIANT, GROUP, engine, { "run-scroll": "inline" });
      await page.locator(".acpmux-scroll").evaluate((node, selector) => {
        node.querySelector<HTMLElement>(selector)!.dataset.glideProbe = "true";
        node.scrollTop = node.scrollHeight;
      }, GROUP);
      await settled(page);
      const PROBE = "[data-glide-probe]";
      for (const direction of ["open", "close"] as const) {
        // An open at the end leaves the view short of it: the close starts at the very end again.
        if (direction === "close") {
          await page.locator(".acpmux-scroll").evaluate((node) => {
            node.scrollTop = node.scrollHeight;
          });
          await settled(page);
        }
        const before = (await watchOpen(page, PROBE, 0, false))[0]!;
        const frames = await watchOpen(page, PROBE);
        await settled(page);
        const after = (await watchOpen(page, PROBE, 0, false))[0]!;
        // Opening moves the rows under the line down; closing brings the line down by what closed.
        const moving = direction === "open" ? "under" : "line";
        const total = after[moving] - before[moving];
        expect({ direction, moved: total > 40 }).toEqual({ direction, moved: true });
        if (direction === "open")
          for (const [index, frame] of frames.entries()) {
            const at = { direction, index, ...frame };
            expect({ at, still: Math.abs(frame.line - before.line) <= 1 }).toEqual({ at, still: true });
          }
        const tops = [before[moving], ...frames.map((frame) => frame[moving])];
        let largest = 0;
        for (let index = 1; index < tops.length; index++)
          largest = Math.max(largest, Math.abs(tops[index]! - tops[index - 1]!));
        // Frames strictly between where it was and where it settles: the glide, not a jump.
        const between = frames.filter(
          (frame) => Math.abs(frame[moving] - before[moving]) > 1 && Math.abs(frame[moving] - after[moving]) > 1,
        ).length;
        expect({ direction, between: between >= 3 }).toEqual({ direction, between: true });
        expect({ direction, largest, smooth: largest <= Math.abs(total) * 0.7 }).toEqual({
          direction,
          largest,
          smooth: true,
        });
        if (direction === "close")
          for (const [index, frame] of frames.entries()) {
            const at = { direction, index, ...frame };
            expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
            expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
          }
      }
      await page.close();
      if (engine !== browser) await engine.close();
    });

  /// A shell block's "Show all N lines" under a log whose top is above the view holds the control
  /// itself, as anywhere in the chat (foldAnchor.ts `foldHoldTarget`): it stays under the pointer on
  /// every frame, the lines it shows come in above it, and the rows under it and the view's end stay.
  test("at the very bottom, a shell block's Show all lines stays under the pointer and its log rises", async () => {
    // Its play opens and closes the group (three toggles at once mid-play): wait on the row itself.
    // This oracle follows the transcript end while output grows, so it uses the inline run arm.
    const page = await open("collapse-tall-group", '[data-row-id="expand-at-bottom-run"]', browser!, {
      "run-scroll": "inline",
    });
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 60_000,
    });
    await settled(page);
    // The control-hold branch applies only after the row's top scrolls above the view. The
    // collapsed call defaults make this fixture shorter, so use a viewport its log exceeds.
    await page.setViewportSize({ width: 900, height: 400 });
    const scrollToEnd = async () => {
      await page.locator(".acpmux-scroll").evaluate((node) => {
        node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
        node.scrollTop = node.scrollHeight;
        node.dispatchEvent(new Event("scroll"));
      });
      await settled(page);
    };
    await scrollToEnd();
    await clickLine(page, GROUP);
    await settled(page);
    await page.evaluate(() => {
      [
        ...document.querySelectorAll<HTMLElement>(
          '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded="false"]',
        ),
      ]
        .at(-1)!
        .setAttribute("data-shell-probe", "");
    });
    await scrollToEnd();
    await clickLine(page, "[data-shell-probe]");
    await settled(page);
    await scrollToEnd();
    const MORE = '[data-row-id="expand-at-bottom-run"] .cv-output-more[aria-expanded="false"]';
    await page.locator(MORE).last().waitFor();
    await page
      .locator(MORE)
      .last()
      .evaluate((node) => node.setAttribute("data-more-probe", ""));
    const PROBE = "[data-more-probe]";
    const before = (await watchOpen(page, PROBE, 0, false))[0]!;
    expect(before.fromEnd).toBeLessThanOrEqual(2);
    const aboveView = await page
      .locator(PROBE)
      .evaluate(
        (node) =>
          node.closest(".acpmux-row")!.getBoundingClientRect().top <
          node.closest(".acpmux-scroll")!.getBoundingClientRect().top - 0.5,
      );
    expect(aboveView).toBe(true);
    const frames = await watchOpen(page, PROBE);
    await settled(page);
    const after = (await watchOpen(page, PROBE, 0, false))[0]!;
    expect(await page.locator(PROBE).getAttribute("aria-expanded")).toBe("true");
    console.log(`shell Show all lines: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
    for (const [index, frame] of frames.entries()) {
      const at = { index, ...frame };
      expect({ at, still: Math.abs(frame.control - before.control) <= 1 }).toEqual({ at, still: true });
      expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
    }
    expect(Math.abs(after.control - before.control)).toBeLessThanOrEqual(1);
    expect(before.line - after.line).toBeGreaterThan(40);
    expect(after.fromEnd).toBeLessThanOrEqual(2);
    await page.close();
  });

  /// The scene's own plays (ExpandAtBottom.gallery.ts) check where the bottom and the clicked line
  /// end up; each throws, and the stage reports it, when they are off. Leo, 2026-11-03: "it's weird
  /// to collapse and get all that empty space at the bottom".
  for (const variant of ["expand-at-bottom", "collapse-at-bottom", "collapse-tall-group", "expand-away"]) {
    test(`gallery play ${variant}`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
      await page.addInitScript(() => localStorage.clear());
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
        timeout: 60_000,
      });
      const report = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      );
      await page.close();
      expect(playFailures(report)).toEqual([]);
    });
  }

  test("away from the bottom, opening a line keeps it put and grows its body down", async () => {
    const page = await open();
    // The earlier turn's "Worked for" line, 160px under the view's top, the rest of the chat under it.
    const MID = "[data-mid-probe]";
    await page.locator(".acpmux-scroll").evaluate((node) => {
      const line = [...node.querySelectorAll<HTMLElement>(".cv-worked")].at(-2)!;
      line.dataset.midProbe = "true";
      node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - 160;
    });
    await settled(page);
    const where = (query: string) =>
      page.evaluate((selector) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const line = document.querySelector<HTMLElement>(selector)!;
        return {
          line: line.getBoundingClientRect().top,
          open: line.getAttribute("aria-expanded"),
          scrollTop: scroller.scrollTop,
          scrollHeight: scroller.scrollHeight,
          fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        };
      }, query);
    const before = await where(MID);
    expect(before.open).toBe("false");
    expect(before.fromEnd).toBeGreaterThan(40);
    await clickLine(page, MID);
    await settled(page);
    const after = await where(MID);
    expect(after.open).toBe("true");
    // The line stays on its pixel and the view where it was; what opened grew the chat downward.
    expect(Math.abs(after.line - before.line)).toBeLessThanOrEqual(1);
    expect(Math.abs(after.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 20);
    await page.close();
  });
});
