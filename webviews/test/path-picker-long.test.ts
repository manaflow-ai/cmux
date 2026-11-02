// The path picker over a folder long enough to virtualize (300 folders): the filter field keeps its
// 30 px instead of being squeezed by the list's full height, and the folder rows sit one row-pitch
// apart, the first one under the Locations included, instead of overlapping the next.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("path-picker-long.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/path-picker-long.html";
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

  test("a folder that virtualizes keeps the field's height and its rows apart", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 620, height: 620 } });
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.locator(".ve-picker-list.ui-virtual .ve-picker-row:not([data-location])").first().waitFor();
    const m = await page.evaluate(() => {
      const field = document.querySelector(".ve-picker-field")!.getBoundingClientRect();
      const rows = [...document.querySelectorAll(".ve-picker-list .ve-picker-row")].map((row) =>
        row.getBoundingClientRect(),
      );
      const overlaps = rows.slice(1).map((row, index) => Math.round(rows[index]!.bottom - row.top));
      return { fieldHeight: field.height, rows: rows.length, overlaps };
    });
    await page.close();
    expect(m.fieldHeight).toBe(30);
    expect(m.rows).toBeGreaterThan(8);
    expect(m.overlaps.filter((overlap) => overlap > 0)).toEqual([]);
  });

  test("filtering a scrolled folder brings its highlighted row back on screen even at the same index", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 620, height: 620 } });
    try {
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      const field = page.locator(".ve-picker-field");
      const list = page.locator(".ve-picker-list.ui-virtual");
      await list.waitFor();
      // All 300 fixture folders begin "surface"; both filters keep the first option at index 0.
      await field.fill("s");
      await page.waitForFunction(() => document.querySelector<HTMLInputElement>(".ve-picker-field")?.value === "s");
      const highlighted = await field.getAttribute("aria-activedescendant");
      await list.evaluate((element) => {
        element.scrollTop = 1500;
        element.dispatchEvent(new Event("scroll"));
      });
      await page.waitForFunction(() => {
        const list = document.querySelector<HTMLElement>(".ve-picker-list.ui-virtual");
        return list !== null && list.scrollTop > 1000;
      });
      await field.press("u");
      await page.waitForFunction(() => document.querySelector<HTMLInputElement>(".ve-picker-field")?.value === "su");
      expect(await field.getAttribute("aria-activedescendant")).toBe(highlighted);
      // The active descendant stays index 0 but must be visible after the new result set.
      const state = await page.evaluate(() => {
        const field = document.querySelector<HTMLInputElement>(".ve-picker-field")!;
        const scroller = document.querySelector<HTMLElement>(".ve-picker-list.ui-virtual")!;
        const active = document.getElementById(field.getAttribute("aria-activedescendant")!)!;
        const row = active.getBoundingClientRect();
        const box = scroller.getBoundingClientRect();
        return {
          selected: active.getAttribute("aria-selected"),
          visible: row.top >= box.top - 1 && row.bottom <= box.bottom + 1,
          scrollTop: scroller.scrollTop,
        };
      });
      expect(state.selected).toBe("true");
      expect(state.visible).toBe(true);
    } finally {
      await page.close();
    }
  });
});
