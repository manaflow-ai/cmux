// cmux-web-test-timeout: 240
// Leo 2026-10-29, on a started chat's model menu with OpenCode selected: "This fucking minimum space
// is just asinine." The rail had `contain: size`, so it added no height: a tab with one Fork row
// shrank the menu to that row, and the rail scrolled Claude Code out of view. Real Chromium lays
// the menu out with the pane's styles; the menu must fit its whole rail, whichever tab shows.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("model-menu-fit.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("model-menu-fit: skipping (run `bunx playwright install chromium`)");
    describe.skip("model menu fit", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
    await warmViteServer(vite, "/test/browser/model-menu-fit.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function opened(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 640, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-menu-fit.html`);
    await page.click(".acpmux-picker-button");
    await page.waitForSelector(".acpmux-quick-menu .acpmux-quick-rail-tab");
    return page;
  }

  /// Every rail tab lies inside the rail's visible box, and the rail does not scroll.
  const railFits = (page: Page) =>
    page.$eval(".acpmux-quick-rail", (rail) => {
      const box = rail.getBoundingClientRect();
      const tabs = [...rail.querySelectorAll(".acpmux-quick-rail-tab")].map((tab) => tab.getBoundingClientRect());
      return {
        scrolls: rail.scrollHeight > rail.clientHeight + 1,
        clipped: tabs.filter((tab) => tab.top < box.top - 1 || tab.bottom > box.bottom + 1).length,
        tabs: tabs.length,
      };
    });

  test("the chat's own tab lists its models and the whole rail", async () => {
    const page = await opened();
    const rows = await page.$$eval(".acpmux-quick-body [role='menuitemradio'] .acpmux-menu-label", (nodes) =>
      nodes.map((node) => node.textContent),
    );
    expect(rows).toContain("Opus 5.5");
    expect(await railFits(page)).toEqual({ scrolls: false, clipped: 0, tabs: 4 });
    await page.close();
  });

  test("a tab with one Fork row keeps the menu as tall as its rail", async () => {
    const page = await opened();
    await page.click('.acpmux-quick-rail-tab[aria-label="OpenCode"]');
    await page.waitForSelector('.acpmux-quick-body :text("Fork to OpenCode")');
    expect(await railFits(page)).toEqual({ scrolls: false, clipped: 0, tabs: 4 });
    // The menu is sized by its content: the layout is no taller than the taller of its two columns.
    const fit = await page.$eval(".acpmux-quick-layout", (layout) => {
      const rail = layout.querySelector(".acpmux-quick-rail")!;
      const list = layout.querySelector(".acpmux-quick-list")!;
      return Math.round(layout.getBoundingClientRect().height - Math.max(rail.scrollHeight, list.scrollHeight));
    });
    expect(Math.abs(fit)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
