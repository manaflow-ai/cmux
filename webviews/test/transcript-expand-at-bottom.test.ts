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
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
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

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.locator(GROUP).waitFor();
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
