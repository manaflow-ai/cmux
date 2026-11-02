// cmux-web-test-timeout: 240
// Leo 2026-10-28, on the compact model menu: "AND I THINK IT'S ALL SO STUPIDLY SPACED AND STYLED
// IT'S FUCKING TONKA TOYS". Real Chromium lays the menu out with the pane's styles and holds it to a
// native macOS menu's density: 28px rows, 24px submenu rows, 13px chrome type, 16px marks, a small
// switch, the check centred on its label's line, and no fade-in when it opens.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("model-menu-density.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("model-menu-density: skipping (run `bunx playwright install chromium`)");
    describe.skip("model menu density", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/model-menu-density.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function opened(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 640, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-menu-density.html`);
    await page.click(".acpmux-picker-button");
    await page.waitForSelector(".acpmux-quick-menu .acpmux-quick-item");
    return page;
  }

  const heights = (page: Page, selector: string) =>
    page.$$eval(selector, (nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().height)));

  test("rows, rail tabs and the search field are a native menu's 28px, in 13px type", async () => {
    const page = await opened();
    const rows = await heights(page, ".acpmux-quick-menu:not(.acpmux-quick-submenu) .ui-menu-item.acpmux-quick-item");
    expect(rows.length).toBeGreaterThan(3);
    expect(rows.every((height) => height === 28)).toBe(true);
    expect((await heights(page, ".acpmux-quick-rail-tab")).every((height) => height === 28)).toBe(true);
    expect(await heights(page, ".acpmux-quick-search")).toEqual([28]);
    const type = await page.$$eval(
      ".acpmux-quick-menu .acpmux-quick-item .acpmux-menu-label, .acpmux-quick-rail-tab, .acpmux-quick-search input",
      (nodes) => [...new Set(nodes.map((node) => getComputedStyle(node).fontSize))],
    );
    expect(type).toEqual(["13px"]);
    const marks = await page.$$eval(".acpmux-quick-rail-tab svg", (nodes) =>
      nodes.map((node) => Math.round(node.getBoundingClientRect().height)),
    );
    expect(marks.length).toBeGreaterThan(0);
    expect(marks.every((height) => height <= 16)).toBe(true);
    await page.close();
  });

  test("the Fast mode switch is small", async () => {
    const page = await opened();
    const size = await page.$eval(".acpmux-quick-fast-toggle", (node) => {
      const box = node.getBoundingClientRect();
      const row = node.closest(".ui-menu-item")!.getBoundingClientRect();
      return { width: Math.round(box.width), height: Math.round(box.height), inset: row.right - box.right };
    });
    // It sits inside its row's inset, not across the row's edge.
    expect(size.inset).toBeGreaterThanOrEqual(4);
    expect(size.height).toBeLessThanOrEqual(16);
    expect(size.width).toBeLessThanOrEqual(28);
    await page.close();
  });

  test("the Effort submenu is 24px rows with the check centred on its label's line", async () => {
    const page = await opened();
    await page.hover('.acpmux-quick-menu [role="menuitem"]:has-text("Effort")');
    await page.waitForSelector(".acpmux-quick-submenu .ui-menu-item");
    const rows = await heights(page, ".acpmux-quick-submenu .ui-menu-item");
    expect(rows.length).toBe(6);
    expect(rows.every((height) => height === 24)).toBe(true);
    const offset = await page.$eval(".acpmux-quick-submenu [aria-checked='true']", (row) => {
      const center = (node: Element | null) => {
        const box = node!.getBoundingClientRect();
        return box.top + box.height / 2;
      };
      return Math.abs(center(row.querySelector(".ui-menu-check")) - center(row.querySelector(".acpmux-menu-label")));
    });
    expect(offset).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("the menu opens on the click, with no fade-in", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 640, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/model-menu-density.html`);
    await page.click(".acpmux-picker-button");
    const shown = await page.$eval(".acpmux-quick-menu", (menu) => ({
      opacity: getComputedStyle(menu).opacity,
      animations: menu.getAnimations({ subtree: false }).length,
    }));
    expect(shown).toEqual({ opacity: "1", animations: 0 });
    await page.close();
  });
});
