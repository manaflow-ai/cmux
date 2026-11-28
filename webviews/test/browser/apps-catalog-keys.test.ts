// cmux-web-test-timeout: 900
// l10n-allow-file: fixture listings, not shipped UI.
// The App Store's windowed catalog with the browser's own keys, in a production build of
// test/browser/apps-catalog-visible-only.html (the real page over 1,000 stand-in listings), in
// Chromium and WebKit. Only the rows near the viewport are mounted, so the focused listing's row, the
// rows before and after it and the first and last rows stay mounted: Tab and Shift-Tab go through the
// listings one at a time, and on to the next listing however far the catalog scrolled from the
// focused one.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../../bench/support/benchPage";
import { installPaintedFrames } from "../support/paintedFrames";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("apps-catalog-keys.test.ts", async () => {
  setDefaultTimeout(300_000);
  const CATALOG = ".apps-catalog-section:last-of-type";
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
  let served: BenchPage;
  beforeAll(async () => {
    // bun test runs with NODE_ENV=test, under which Vite's build compiles JSX for React's
    // development runtime; the page is built as it ships.
    const mode = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/apps-catalog-visible-only.html", { dev: false });
    } finally {
      process.env.NODE_ENV = mode;
    }
    for (const name of Object.keys(engines) as (keyof typeof engines)[])
      browsers[name] = await engines[name].launch({ headless: true });
  }, 300_000);
  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser?.close();
    await served?.close();
  });

  async function open(engine: keyof typeof engines, layout: "grid" | "list", width = 1200): Promise<Page> {
    const page = await browsers[engine]!.newPage({ viewport: { width, height: 800 } });
    await installPaintedFrames(page);
    await gotoBenchPage(page, { ...served, url: `${served.url}#n=1000&layout=${layout}` });
    await requireProductionReact(page, { dev: served.dev });
    await page.waitForFunction(
      (catalog) => window.benchReady === true && !!document.querySelector(`${catalog} [data-app]`),
      CATALOG,
    );
    await page.evaluate(() => window.cmuxPaintFrame());
    return page;
  }

  /** The listing whose card or row holds focus, by its place in the catalog; -1 outside it. */
  const focused = (page: Page) =>
    page.evaluate((catalog) => {
      const app = document.activeElement?.closest<HTMLElement>(`${catalog} [data-app]`)?.dataset.app;
      return app ? Number(app.split("-").pop()) : -1;
    }, CATALOG);

  /** Focuses listing `index`'s first or last tab stop, scrolling the catalog to it first. */
  async function focusListing(page: Page, index: number, stop: "first" | "last") {
    await page.evaluate(
      async ({ catalog, index }) => {
        const scroller = document.querySelector<HTMLElement>(".apps-scroll")!;
        const card = () => document.querySelector(`${catalog} [data-app="acme.tool-${index}"]`);
        // Down a viewport a frame until the listing is mounted.
        while (!card()) await window.cmuxPaintFrame(() => (scroller.scrollTop += scroller.clientHeight));
      },
      { catalog: CATALOG, index },
    );
    const stops = page.locator(`${CATALOG} [data-app="acme.tool-${index}"] button`);
    await (stop === "first" ? stops.first() : stops.last()).focus();
    await page.evaluate(() => window.cmuxPaintFrame());
  }

  /** Moves the catalog's scroll by `by` px (to the top with `"top"`) and waits for it to paint. */
  async function scrollCatalog(page: Page, by: number | "top") {
    await page.evaluate(async (by) => {
      const scroller = document.querySelector<HTMLElement>(".apps-scroll")!;
      await window.cmuxPaintFrame(() => {
        scroller.scrollTop = by === "top" ? 0 : scroller.scrollTop + by;
      });
      await window.cmuxPaintFrame();
    }, by);
  }

  /** Presses `key` until focus reaches listing `to` (or leaves the catalog); the listings it went through. */
  async function walk(page: Page, key: "Tab" | "Shift+Tab", to: number): Promise<number[]> {
    const path = [await focused(page)];
    for (let press = 0; press < 1_000 && path.at(-1) !== to && path.at(-1)! >= 0; press++) {
      await page.keyboard.press(key);
      const at = await focused(page);
      if (at !== path.at(-1)) path.push(at);
    }
    return path;
  }

  for (const engine of Object.keys(engines) as (keyof typeof engines)[])
    for (const layout of ["grid", "list"] as const) {
      test(`${engine} ${layout}: Tab goes through 200 listings one at a time, and Shift-Tab back`, async () => {
        const page = await open(engine, layout);
        try {
          await focusListing(page, 0, "first");
          expect(await walk(page, "Tab", 199)).toEqual(Array.from({ length: 200 }, (_, index) => index));
          expect(await walk(page, "Shift+Tab", 0)).toEqual(Array.from({ length: 200 }, (_, index) => 199 - index));
        } finally {
          await page.close();
        }
      });

      test(`${engine} ${layout}: Tab from a focused listing the catalog scrolled 20,000 px away goes to the next listing`, async () => {
        const page = await open(engine, layout);
        try {
          // The last listing of the first row in the grid (four columns at 1200 px), so the next is on the next row.
          await focusListing(page, 3, "last");
          await scrollCatalog(page, 20_000);
          await page.keyboard.press("Tab");
          expect(await focused(page)).toBe(4);
          await page.keyboard.press("Shift+Tab");
          expect(await focused(page)).toBe(3);
        } finally {
          await page.close();
        }
      });

      test(`${engine} ${layout}: Tab from a focused listing far down, after scrolling back to the top, goes to the next listing`, async () => {
        const page = await open(engine, layout);
        try {
          await focusListing(page, 403, "last");
          await scrollCatalog(page, "top");
          await page.keyboard.press("Tab");
          expect(await focused(page)).toBe(404);
        } finally {
          await page.close();
        }
      });
    }
});
