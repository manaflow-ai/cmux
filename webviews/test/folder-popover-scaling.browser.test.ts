// cmux-web-test-timeout: 300
// The composer's folder popover is as wide as its chrome type needs, the way the model picker is
// (cmux#38864): at the default size its search placeholder and a typical repository row read whole,
// and Interface Size or a larger chrome text size widens it in proportion.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("folder-popover-scaling.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  const entry = "agent-pane.composer-context";
  const variant = "lane-checkouts";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, entry, { browser: browsers.get("chromium"), params: { variant } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(engine: string, width = 1000) {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 700 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height: 700 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-folder-popover .acpmux-location-search").waitFor();
    return page;
  }

  const layout = (page: Page) =>
    page.evaluate(() => {
      const menu = document.querySelector<HTMLElement>(".acpmux-folder-popover")!;
      const field = menu.querySelector<HTMLInputElement>(".acpmux-location-search")!;
      const style = getComputedStyle(field);
      const context = document.createElement("canvas").getContext("2d")!;
      context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
      const rows = [...menu.querySelectorAll<HTMLElement>(".acpmux-location-row:not([data-worktree])")].map((row) => {
        const name = row.querySelector<HTMLElement>(".acpmux-location-name")!;
        return {
          label: row.querySelector(".acpmux-menu-label")!.textContent!,
          clipped: name.scrollWidth > name.clientWidth + 1,
        };
      });
      return {
        width: menu.getBoundingClientRect().width,
        placeholderFits: context.measureText(field.placeholder).width <= field.clientWidth - padding + 1,
        rows,
      };
    });

  const settle = (page: Page, width: number) =>
    page.waitForFunction(
      (min) => document.querySelector(".acpmux-folder-popover")!.getBoundingClientRect().width > min,
      width,
    );

  for (const engine of ["chromium", "webkit"]) {
    test(`${engine}: the search placeholder and typical repository rows read whole at the default size`, async () => {
      const page = await open(engine);
      try {
        const initial = await layout(page);
        expect(initial.placeholderFits).toBe(true);
        // A repository with lanes (badge, name, worktree count, check) and a longer plain name.
        for (const label of ["cmux", "leo-workspace"]) {
          const row = initial.rows.find((candidate) => candidate.label === label);
          expect(row, label).toBeDefined();
          expect(row!.clipped, label).toBe(false);
        }
      } finally {
        await page.close();
      }
    });

    test(`${engine}: the popover widens in proportion to Interface Size and chrome text size`, async () => {
      const page = await open(engine);
      try {
        const initial = await layout(page);
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        await settle(page, initial.width * 1.45);
        const scaled = await layout(page);
        expect(scaled.width).toBeGreaterThanOrEqual(initial.width * 1.45);
        expect(scaled.width).toBeLessThanOrEqual(initial.width * 1.55);
        expect(scaled.placeholderFits).toBe(true);
        await page.evaluate(() => {
          document.documentElement.style.setProperty("--cmux-interface-scale", "1");
          document.documentElement.style.setProperty("--text-body", "20px");
        });
        await settle(page, initial.width * 1.45);
        expect((await layout(page)).width).toBeGreaterThanOrEqual(initial.width * 1.45);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: a narrow pane keeps the popover inside the window`, async () => {
      const page = await open(engine, 320);
      try {
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        await page.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        const box = (await page.locator(".acpmux-folder-popover").boundingBox())!;
        expect(box.x).toBeGreaterThanOrEqual(0);
        expect(box.x + box.width).toBeLessThanOrEqual(320 + 0.5);
      } finally {
        await page.close();
      }
    });
  }
});
