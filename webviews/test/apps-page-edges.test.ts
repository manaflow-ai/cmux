// The App Store's Discover list shares the toolbar's edges: the chips and the grid start under the
// tabs and end under the search field at any width (a centered 1200px column put them 7px in at
// 1214 and 250px in at 1664), and the Cloud banner sits clear of the toolbar's rule. In the split
// view's 340px list the banner stacks its button under the text and the chips stay on one row.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("apps-page-edges.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/src/pages/apps/index.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(width: number, layout: "grid" | "split") {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width, height: 640 } });
    const app = layout === "split" ? "&app=cmux.coderouter" : "";
    await page.goto(`http://127.0.0.1:${port}${PAGE}?mock#/discover?layout=${layout}${app}`);
    await page.locator(".apps-chip").first().waitFor();
    await page.locator(".apps-cloud-feature").waitFor();
    const m = await page.evaluate((withGrid) => {
      const box = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
      const tops = [...document.querySelectorAll(".apps-chip")].map((chip) => chip.getBoundingClientRect().top);
      const button = box(".apps-cloud-feature .apps-button");
      const text = box(".apps-cloud-feature-text");
      return {
        tabsLeft: box(".apps-tabs").left,
        searchRight: box(".apps-search").right,
        toolbarBottom: box(".apps-toolbar").bottom,
        feature: box(".apps-cloud-feature").toJSON() as DOMRect,
        chips: box(".apps-chips").toJSON() as DOMRect,
        grid: withGrid ? (box(".apps-grid").toJSON() as DOMRect) : undefined,
        chipRows: new Set(tops.map(Math.round)).size,
        buttonBelowText: button.top >= text.bottom,
      };
    }, layout === "grid");
    await page.close();
    return m;
  }

  for (const width of [1214, 1664]) {
    test(`the Discover grid at ${width}px lines up with the toolbar`, async () => {
      const m = await measure(width, "grid");
      expect(Math.round(m.chips.left)).toBe(Math.round(m.tabsLeft));
      expect(Math.round(m.grid!.left)).toBe(Math.round(m.tabsLeft));
      expect(Math.round(m.grid!.right)).toBe(Math.round(m.searchRight));
      expect(m.feature.top - m.toolbarBottom).toBeGreaterThanOrEqual(8);
    });
  }

  test("the split view's list stacks the banner and keeps the chips on one row", async () => {
    const m = await measure(1214, "split");
    expect(m.buttonBelowText).toBe(true);
    expect(m.feature.height).toBeLessThan(180);
    expect(m.chipRows).toBe(1);
  });
});
