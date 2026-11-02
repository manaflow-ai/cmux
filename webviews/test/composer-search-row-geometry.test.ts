import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-search-row-geometry.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer search row geometry", () => test("browser", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  const cases = [
    {
      name: "compact model",
      entry: "agent-pane.model-picker",
      variant: "quick-search-field",
      field: ".acpmux-quick-search",
      row: ".acpmux-quick-item",
    },
    {
      name: "full model",
      entry: "agent-pane.model-picker",
      variant: "curated",
      field: ".acpmux-mp-search",
      row: ".acpmux-mp-row",
    },
    {
      name: "file search",
      entry: "agent-pane.file-search",
      variant: "matches",
      field: ".acpmux-file-search input",
      row: ".acpmux-file-result",
    },
    {
      name: "project search",
      entry: "agent-pane.project-chooser",
      variant: "open-current",
      field: ".acpmux-project-search-field",
      row: ".acpmux-project-menu [role=option]",
    },
  ] as const;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const item of cases) {
      await warmGalleryFrame(vite, item.entry, { browser, params: { variant: item.variant } });
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(page: Page, entry: string, variant: string) {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
  }

  for (const item of cases) {
    test(`${item.name} search row matches its menu rows`, async () => {
      const context = await browser.newContext({ viewport: { width: 760, height: 420 } });
      const page = await context.newPage();
      try {
        await open(page, item.entry, item.variant);
        await page.waitForSelector(item.row);
        const geometry = await page.evaluate(({ field, row }) => {
          const search = document.querySelector<HTMLElement>(field)!;
          const option = document.querySelector<HTMLElement>(row)!;
          const searchStyle = getComputedStyle(search);
          const optionStyle = getComputedStyle(option);
          return {
            searchHeight: search.getBoundingClientRect().height,
            optionHeight: option.getBoundingClientRect().height,
            searchInset: Number.parseFloat(searchStyle.paddingLeft),
            optionInset: Number.parseFloat(optionStyle.paddingLeft),
          };
        }, item);
        if (item.name === "project search") {
          // Project options have a second path line; the search matches their minimum row height.
          expect(geometry.optionHeight).toBeGreaterThanOrEqual(geometry.searchHeight);
          expect(geometry.searchHeight).toBe(28);
        } else {
          expect(Math.abs(geometry.searchHeight - geometry.optionHeight)).toBeLessThanOrEqual(1);
        }
        expect(Math.abs(geometry.searchInset - geometry.optionInset)).toBeLessThanOrEqual(1);
      } finally {
        await context.close();
      }
    });
  }
});
