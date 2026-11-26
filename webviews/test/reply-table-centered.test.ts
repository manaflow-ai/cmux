// Reply Markdown tables center in the conversation column when they fit, while an oversized
// table keeps its own horizontal scroller and starts at the column edge.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reply-table-centered.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reply-table-centered: skipping (run `bunx playwright install chromium`)");
    describe.skip("centered reply tables", () => test("chromium", () => {}));
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.table-block", { browser, params: { variant: "hover", width: 640 } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width = 640): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 760 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (;;) {
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.table-block", { variant, width })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.locator(".cv-table-block").first().waitFor();
    return page;
  };

  const measure = (page: Page) =>
    page.evaluate(() => {
      const block = document.querySelector<HTMLElement>(".cv-table-block")!;
      const wrap = block.querySelector<HTMLElement>(".cv-table-wrap")!;
      const column = block.parentElement!.getBoundingClientRect();
      const rect = block.getBoundingClientRect();
      return {
        leftGap: rect.left - column.left,
        rightGap: column.right - rect.right,
        blockLeft: rect.left,
        columnLeft: column.left,
        wrapWidth: wrap.clientWidth,
        wrapScrollWidth: wrap.scrollWidth,
        pageScrollWidth: document.documentElement.scrollWidth,
        pageClientWidth: document.documentElement.clientWidth,
      };
    });

  test("centers a table that fits its conversation column", async () => {
    const page = await open("hover");
    const layout = await measure(page);
    expect(layout.leftGap).toBeGreaterThan(1);
    expect(Math.abs(layout.leftGap - layout.rightGap)).toBeLessThan(1);
    await page.close();
  });

  test("keeps an oversized table scrolling inside the conversation column", async () => {
    const page = await open("unbreakable", 420);
    const layout = await measure(page);
    expect(layout.wrapScrollWidth).toBeGreaterThan(layout.wrapWidth + 1);
    expect(Math.abs(layout.blockLeft - layout.columnLeft)).toBeLessThan(1);
    expect(layout.pageScrollWidth).toBeLessThanOrEqual(layout.pageClientWidth + 1);
    await page.close();
  });
});
