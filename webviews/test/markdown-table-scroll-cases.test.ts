// Markdown tables scroll sideways, and show that they do (MARKDOWN-TABLE-SCROLL, user 2026-10-20:
// "Horizontal scroll for the Markdown viewer is definitely broken... fix it properly such that it's
// intuitive"). The real markdown page (gallery entry pages.markdown, variant table-scroll) holds the
// user's five cases from markdown-table-scroll-test.md, in a pane-sized viewport:
//
//   0. a 20-column table, 1. one long unbroken cell, 2. code in cells: wider than the column;
//   3. a 40-row table, 4. a small aligned table: they fit.
//
// A wide table scrolls in its own box (a sideways wheel, the trackpad swipe and Shift-wheel), the
// page never scrolls sideways, nothing reaches past the pane's edge, the last column can be
// reached, and a vertical wheel over any table scrolls the page. No edge of a table is ever faded
// out: the text past the edge shows as is, and the box's thin sideways scrollbar says it scrolls
// (user 2026-10-31, on a faded table edge: "why blur?"). A table that fits does not scroll.
//
// One page per engine for every test, reset between tests, so a run takes seconds once Vite is
// warm. The app draws the page in WebKit; Chromium runs too. An engine not installed is skipped.
// The layout half (a columns screen kept the swipe for its strip) is PaneHorizontalScrollClaimTests.
import { afterAll, beforeAll, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-table-scroll-cases.test.ts", async () => {
  setDefaultTimeout(60_000);
  const only = process.env.CMUX_MD_TABLE_ENGINES?.split(",");
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`markdown-table-scroll-cases: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("markdown table scroll cases", () => test("no engine", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers: Browser[] = [];
  const pages = new Map<string, Page>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    for (const [, type] of engines) browsers.push(await type.launch({ headless: true }));
    await warmGalleryFrame(vite, "pages.markdown", { browser: browsers[0], params: { variant: "table-scroll" } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    for (const [index, [name]] of engines.entries()) {
      const page = await browsers[index]!.newPage({ viewport: { width: 640, height: 520 } });
      for (let attempt = 1; ; attempt++) {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.markdown", { variant: "table-scroll" })}`);
        try {
          // A cold Vite optimizer takes up to a minute on a busy box; a warm cache, a second or two.
          await page.waitForFunction(() => document.querySelectorAll(".md-prose .tableWrapper").length === 5, null, {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          // Vite's dependency optimizer can reload the first page while it compiles.
          if (attempt === 3 || !/context was destroyed|navigat|Timeout/i.test(String(error))) throw error;
        }
      }
      pages.set(name, page);
    }
  }, 400_000);
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
    await vite?.close();
  });

  /** The page scroller and each table's box: offsets, sizes, edges and the fade it shows. */
  const measure = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".md-scroll")!;
      const pane = scroller.getBoundingClientRect();
      const tables = [...document.querySelectorAll<HTMLElement>(".md-prose .tableWrapper")].map((box) => {
        const rect = box.getBoundingClientRect();
        const lastCell = box.querySelector("tr:first-child > :last-child")!.getBoundingClientRect();
        const style = getComputedStyle(box);
        // WebKit can report the unprefixed property as "none" beside the prefixed value.
        const masks = [style.maskImage, style.webkitMaskImage].filter((value) => value && value !== "none");
        return {
          left: box.scrollLeft,
          maxLeft: box.scrollWidth - box.clientWidth,
          clientWidth: box.clientWidth,
          scrollWidth: box.scrollWidth,
          rectLeft: rect.left,
          rectRight: rect.right,
          lastCellRight: lastCell.right,
          fades: masks.length > 0,
          sidewaysScrollbar: box.hasAttribute("data-cmux-sideways-scroller"),
        };
      });
      return {
        page: {
          left: scroller.scrollLeft,
          top: scroller.scrollTop,
          clientWidth: scroller.clientWidth,
          scrollWidth: scroller.scrollWidth,
          left0: pane.left,
          right: pane.right,
        },
        tables,
      };
    });

  /** Puts table `index` in view (the page scrolled to it) and returns a point over it. */
  const over = async (page: Page, index: number) => {
    const box = page.locator(".md-prose .tableWrapper").nth(index);
    await box.scrollIntoViewIfNeeded();
    const rect = (await box.boundingBox())!;
    // A table taller than the pane starts above it, under the toolbar: aim at the middle of the
    // part that shows.
    const top = Math.max(rect.y, 0);
    const bottom = Math.min(rect.y + rect.height, page.viewportSize()!.height);
    return { x: rect.x + Math.min(rect.width / 2, 200), y: (top + bottom) / 2 };
  };

  /** Wheels at `point` and waits for the scroll to land (two frames). */
  const wheel = async (page: Page, point: { x: number; y: number }, dx: number, dy: number) => {
    await page.mouse.move(point.x, point.y);
    await page.mouse.wheel(dx, dy);
    await page.evaluate(
      () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 30)))),
    );
  };

  const WIDE = [0, 1];
  const FITS = [3, 4];

  for (const [engine] of engines)
    describe(`markdown table scroll cases (${engine})`, () => {
      const page = () => pages.get(engine)!;

      beforeEach(async () => {
        await page().evaluate(() => {
          for (const box of document.querySelectorAll<HTMLElement>(".md-prose .tableWrapper")) box.scrollLeft = 0;
          const scroller = document.querySelector<HTMLElement>(".md-scroll")!;
          scroller.scrollTop = 0;
          scroller.scrollLeft = 0;
        });
        await page().keyboard.up("Shift");
      });

      test("wide tables overflow their own box, tables that fit do not, and nothing passes the pane edge", async () => {
        const { page: pane, tables } = await measure(page());
        expect(pane.scrollWidth).toBeLessThanOrEqual(pane.clientWidth + 1);
        for (const index of WIDE) expect(tables[index]!.maxLeft).toBeGreaterThan(50);
        for (const index of FITS) expect(tables[index]!.maxLeft).toBeLessThanOrEqual(1);
        for (const table of tables) {
          expect(table.rectLeft).toBeGreaterThanOrEqual(pane.left0 - 1);
          expect(table.rectRight).toBeLessThanOrEqual(pane.right + 1);
        }
      });

      test("a sideways swipe over a wide table scrolls that table, not the page", async () => {
        for (const index of [...WIDE, 2]) {
          const before = (await measure(page())).tables[index]!;
          if (before.maxLeft <= 1) continue; // code cells that wrapped to fit
          await wheel(page(), await over(page(), index), 240, 0);
          const after = await measure(page());
          expect(after.tables[index]!.left).toBeGreaterThan(0);
          expect(after.page.left).toBe(0);
        }
      });

      test("Shift-wheel over a wide table scrolls it sideways", async () => {
        const point = await over(page(), 0);
        const top = (await measure(page())).page.top;
        await page().keyboard.down("Shift");
        await wheel(page(), point, 0, 240);
        await page().keyboard.up("Shift");
        const after = await measure(page());
        expect(after.tables[0]!.left).toBeGreaterThan(0);
        expect(after.page.left).toBe(0);
        expect(after.page.top).toBe(top);
      });

      test("the last column of a wide table can be scrolled fully into view", async () => {
        for (const index of WIDE) {
          const point = await over(page(), index);
          for (let i = 0; i < 6; i++) await wheel(page(), point, 1200, 0);
          const table = (await measure(page())).tables[index]!;
          expect(table.left).toBeGreaterThanOrEqual(table.maxLeft - 1);
          expect(table.lastCellRight).toBeLessThanOrEqual(table.rectRight + 1);
        }
      });

      test("a sideways swipe over a table that fits moves nothing", async () => {
        for (const index of FITS) {
          await wheel(page(), await over(page(), index), 240, 0);
          const after = await measure(page());
          expect(after.tables[index]!.left).toBe(0);
          expect(after.page.left).toBe(0);
        }
      });

      test("a vertical wheel over a wide or a tall table scrolls the page", async () => {
        for (const index of [0, 3]) {
          const point = await over(page(), index);
          const before = await measure(page());
          // Toward whichever end the page can still move (the tall table can sit at the bottom).
          const dy = before.page.top > 0 ? -160 : 160;
          await wheel(page(), point, 0, dy);
          const after = await measure(page());
          expect(after.page.top).not.toBe(before.page.top);
          expect(after.tables[index]!.left).toBe(0);
        }
      });

      test("no table edge is faded at the start, middle or end of a scroll; the box shows its thin scrollbar", async () => {
        const start = (await measure(page())).tables;
        for (const table of start) {
          expect(table.fades).toBe(false);
          expect(table.sidewaysScrollbar).toBe(true);
        }
        const point = await over(page(), 0);
        await wheel(page(), point, 160, 0);
        expect((await measure(page())).tables[0]!.fades).toBe(false);
        for (let i = 0; i < 6; i++) await wheel(page(), point, 1200, 0);
        expect((await measure(page())).tables[0]!.fades).toBe(false);
      });
    });
});
