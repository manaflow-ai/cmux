// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a line with the transcript at its very bottom pushes the text up (Leo, 2026-11-02: "YOU
// EXPAND UP WHILE YOUR SCCROLL IS AT THE VERY BOTTOM AKA YOU FUCKING PUSH THE TEXT UP VISUALLY INSTEAD
// OF EXPANDING DOWN LIKE USUAL / JUST THAT CASE"): the view stays at its end, the rows under the
// opened line stay on their pixels, and the line itself moves up by what opened. Anywhere else the
// line stays put and its body grows down (#28780).
//
// Real Chromium from Playwright on the agent pane's gallery scene (ExpandAtBottom.gallery.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { installPaintedFrames } from "./support/paintedFrames";
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

  async function open(variant = VARIANT, ready = GROUP, engine: Browser = browser!): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await engine.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(ready).waitFor();
    await settled(page);
    return page;
  }

  test("at the very bottom, opening a line keeps the bottom and pushes the text above up", async () => {
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
    // Still at the very bottom, and the rows under the line did not move.
    expect(after.fromEnd).toBeLessThanOrEqual(2);
    expect(Math.abs(after.lastFoot - before.lastFoot)).toBeLessThanOrEqual(2);
    // What opened pushed the line (and the text above it) up by its height.
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(before.line - after.line).toBeGreaterThan(40);
    await page.close();
  });

  test("at the very bottom, a long prompt's Show more opens it by pushing the text above up", async () => {
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
          prompt: bubbles.at(-1)!.getBoundingClientRect().top,
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
    expect(after.fromEnd).toBeLessThanOrEqual(2);
    expect(Math.abs(after.lastFoot - before.lastFoot)).toBeLessThanOrEqual(2);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(before.prompt - after.prompt).toBeGreaterThan(40);
    await page.close();
  });

  /// Clicks `query` (unless `click` is false) and reads every painted frame for `ms`: the opened row's
  /// top (a Show more under its text stays at the row's foot, the text above it rises), the first row
  /// under it and the last row's foot, how far the view is from its end, and how far below the row
  /// under it the opened row is drawn (its foot less its clip).
  const watchOpen = async (page: Page, query: string, ms = 700, click = true) => {
    const watching = page.evaluate(
      ({ selector, duration }) =>
        new Promise<{ line: number; under: number; last: number; fromEnd: number; over: number }[]>((resolve) => {
          const frames: { line: number; under: number; last: number; fromEnd: number; over: number }[] = [];
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

  /// Leo, 2026-11-03: "you guys adding fake space or whatever / it grows and shrinks right / ... when
  /// you expand tool calls at the very bottom / you push the text above upwards / you don't expand
  /// down IN THAT CASE". Not only where it settles: on every frame of the fold the rows under the line
  /// keep their pixels and nothing of what opened shows under the line's old foot.
  for (const [variant, query] of [
    [VARIANT, GROUP],
    ["prompt", '.cv-user__more[aria-expanded="false"]'],
  ] as const) {
    test(`at the very bottom (${variant}), no frame opens room under the line: only the text above moves up`, async () => {
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
      let line = before.line;
      for (const [index, frame] of frames.entries()) {
        const at = { index, ...frame };
        expect({ at, under: Math.abs(frame.under - before.under) <= 1 }).toEqual({ at, under: true });
        expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
        expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
        expect({ at, covered: frame.over <= 1 }).toEqual({ at, covered: true });
        expect({ at, up: frame.line <= line + 0.5 }).toEqual({ at, up: true });
        line = frame.line;
      }
      expect(before.line - frames.at(-1)!.line).toBeGreaterThan(40);
      await page.close();
    });
  }

  /// Leo, 2026-11-04: "how come there aren't animatiosn for expanding/collapsing tool calls
  /// anymore???", and on the bottom case: "it's not a smooth eough/graceful enough/minimally shifting
  /// animation". Opening and then closing "Ran 2 commands" at the very bottom glides: the line moves
  /// over several painted frames, never most of the way in one, while the view stays at its end and
  /// the rows under the line keep their pixels on every frame.
  // In Chromium and in WebKit, the app's own engine (where the thread slide this replaced jumped).
  for (const engineName of ["chromium", "webkit"] as const)
    test(`at the very bottom (${engineName}), opening and closing a group glide the text above over several frames`, async () => {
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
      const page = await open(VARIANT, GROUP, engine);
      await page.locator(".acpmux-scroll").evaluate((node, selector) => {
        node.querySelector<HTMLElement>(selector)!.dataset.glideProbe = "true";
        node.scrollTop = node.scrollHeight;
      }, GROUP);
      await settled(page);
      const PROBE = "[data-glide-probe]";
      for (const direction of ["open", "close"] as const) {
        const before = (await watchOpen(page, PROBE, 0, false))[0]!;
        const frames = await watchOpen(page, PROBE);
        await settled(page);
        const after = (await watchOpen(page, PROBE, 0, false))[0]!;
        const total = after.line - before.line;
        // Opening moves the line up, closing brings it back down, by what opened.
        expect({ direction, moved: direction === "open" ? total < -40 : total > 40 }).toEqual({
          direction,
          moved: true,
        });
        const tops = [before.line, ...frames.map((frame) => frame.line)];
        let largest = 0;
        for (let index = 1; index < tops.length; index++)
          largest = Math.max(largest, Math.abs(tops[index]! - tops[index - 1]!));
        // Frames strictly between where it was and where it settles: the glide, not a jump.
        const between = frames.filter(
          (frame) => Math.abs(frame.line - before.line) > 1 && Math.abs(frame.line - after.line) > 1,
        ).length;
        expect({ direction, between: between >= 3 }).toEqual({ direction, between: true });
        expect({ direction, largest, smooth: largest <= Math.abs(total) * 0.7 }).toEqual({
          direction,
          largest,
          smooth: true,
        });
        for (const [index, frame] of frames.entries()) {
          const at = { direction, index, ...frame };
          expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
          expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
        }
      }
      await page.close();
      if (engine !== browser) await engine.close();
    });

  /// A control with no height fold of its own (a shell block's "Show all N lines", a failure's
  /// Details) glides too at the very bottom: the thread slides to what it laid out in one step, over
  /// several painted frames, never most of the way in one (router-review F1 on #34780).
  test("at the very bottom, a shell block's Show all lines glides the text above over several frames", async () => {
    // Its play opens and closes the group (three toggles at once mid-play): wait on the row itself.
    const page = await open("collapse-tall-group", '[data-row-id="expand-at-bottom-run"]');
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 60_000,
    });
    await settled(page);
    const scrollToEnd = async () => {
      await page.locator(".acpmux-scroll").evaluate((node) => {
        node.scrollTop = node.scrollHeight;
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
    const frames = await watchOpen(page, PROBE);
    await settled(page);
    const after = (await watchOpen(page, PROBE, 0, false))[0]!;
    expect(await page.locator(PROBE).getAttribute("aria-expanded")).toBe("true");
    const total = after.line - before.line;
    expect(total).toBeLessThan(-40);
    const tops = [before.line, ...frames.map((frame) => frame.line)];
    let largest = 0;
    for (let index = 1; index < tops.length; index++)
      largest = Math.max(largest, Math.abs(tops[index]! - tops[index - 1]!));
    const between = frames.filter(
      (frame) => Math.abs(frame.line - before.line) > 1 && Math.abs(frame.line - after.line) > 1,
    ).length;
    expect({ between: between >= 3, largest, total }).toEqual({ between: true, largest, total });
    expect({ largest, total, smooth: largest <= Math.abs(total) * 0.7 }).toEqual({ largest, total, smooth: true });
    for (const [index, frame] of frames.entries()) {
      const at = { index, ...frame };
      expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
      expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
    }
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
