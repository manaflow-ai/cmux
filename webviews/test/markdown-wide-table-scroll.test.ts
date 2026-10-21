// Wide tables in the markdown viewer scroll sideways (MARKDOWN-TABLE-SCROLL, user 2026-10-19:
// "scrolling in the markdown viewer table horizontally doesnt work"). The real markdown page
// (gallery entry pages.markdown, variant wide-table) in a pane-sized viewport: a 14-column table
// and a long code line, each wider than the reading column. Each one scrolls sideways in its own
// box (a horizontal wheel, the trackpad swipe and Shift-wheel all arrive as deltaX), the page itself
// never scrolls sideways, and a vertical wheel over the table still scrolls the page.
//
// Before the fix the table was its own scroller (`display: block; overflow-x: auto`) but the
// editor's inline `min-width` (100px a column) made it as wide as its content, so it never
// overflowed itself: it spilled out of the column and the whole page scrolled sideways.
//
// The app draws the page in WebKit; Chromium runs too. An engine that is not installed is skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-wide-table-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`markdown-wide-table-scroll: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("markdown wide tables", () => test("no engine", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
    await warmGalleryFrame(vite, "pages.markdown", {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: "wide-table" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 640, height: 520 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await installPaintedFrames(page);
    for (let attempt = 1; ; attempt++) {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.markdown", { variant: "wide-table" })}`);
      try {
        await page.waitForSelector(".md-prose .tableWrapper table td", { timeout: 60_000 });
        await page.waitForSelector(".md-prose .md-code pre", { timeout: 60_000 });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };

  /** Scroll offsets and sizes of the page scroller, the table's box and the code block. */
  const measure = (page: Page) =>
    page.evaluate(() => {
      const box = (selector: string) => {
        const element = document.querySelector<HTMLElement>(selector)!;
        return {
          left: element.scrollLeft,
          top: element.scrollTop,
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
        };
      };
      return { page: box(".md-scroll"), table: box(".md-prose .tableWrapper"), code: box(".md-prose .md-code pre") };
    });

  /** Wheels over the middle of `selector` and waits for the scroll to land: something has moved,
   *  and a painted frame shows it where the one before did. A wheel that moves nothing stops
   *  waiting after 300 frames, and the test's own checks fail. */
  const wheel = async (page: Page, selector: string, dx: number, dy: number) => {
    const rect = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(rect.x + rect.width / 2, rect.y + Math.min(rect.height / 2, 40));
    // The scroll offsets of the page scroller, the table's box and the code block, as one key.
    await page.evaluate(() => {
      const state = window as unknown as { offsets(): string; from: string };
      state.offsets = () =>
        [".md-scroll", ".md-prose .tableWrapper", ".md-prose .md-code pre"]
          .map((at) => {
            const element = document.querySelector<HTMLElement>(at)!;
            return `${element.scrollLeft},${element.scrollTop}`;
          })
          .join(" ");
      state.from = state.offsets();
    });
    await page.mouse.wheel(dx, dy);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const state = window as unknown as { offsets(): string; from: string };
          let last = state.from;
          let left = 300;
          window.cmuxAfterPaint(() => {
            const at = state.offsets();
            const landed = at !== state.from && at === last;
            last = at;
            if (!landed && --left > 0) return true;
            resolve();
            return false;
          });
        }),
    );
  };

  for (const [engine] of engines)
    describe(`markdown wide tables (${engine})`, () => {
      test("the table and the code line overflow their own box, not the page", async () => {
        const page = await open(engine);
        const before = await measure(page);
        expect(before.page.scrollWidth).toBeLessThanOrEqual(before.page.clientWidth + 1);
        expect(before.table.scrollWidth).toBeGreaterThan(before.table.clientWidth + 100);
        expect(before.code.scrollWidth).toBeGreaterThan(before.code.clientWidth + 100);
        await page.close();
      });

      test("a sideways wheel over the table scrolls the table, not the page", async () => {
        const page = await open(engine);
        await wheel(page, ".md-prose .tableWrapper", 240, 0);
        const after = await measure(page);
        expect(after.table.left).toBeGreaterThan(0);
        expect(after.page.left).toBe(0);
        await page.close();
      });

      test("a sideways wheel over the code line scrolls the code block", async () => {
        const page = await open(engine);
        // A wheel lands only on what is on screen: the code block sits below the 14-column table.
        await page.locator(".md-prose .md-code pre").scrollIntoViewIfNeeded();
        await wheel(page, ".md-prose .md-code pre", 240, 0);
        const after = await measure(page);
        expect(after.code.left).toBeGreaterThan(0);
        expect(after.page.left).toBe(0);
        await page.close();
      });

      test("a vertical wheel over the table scrolls the page", async () => {
        const page = await open(engine);
        await wheel(page, ".md-prose .tableWrapper", 0, 240);
        const after = await measure(page);
        expect(after.page.top).toBeGreaterThan(0);
        expect(after.table.left).toBe(0);
        await page.close();
      });

      test('markdown.tables "wrap" fits the table to the column', async () => {
        const page = await open(engine);
        await page.evaluate(() => {
          document.documentElement.dataset.cmuxMdTables = "wrap";
        });
        const after = await measure(page);
        expect(after.table.scrollWidth).toBeLessThanOrEqual(after.table.clientWidth + 1);
        await page.close();
      });
    });
});
