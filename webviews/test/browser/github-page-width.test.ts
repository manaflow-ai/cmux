// l10n-allow-file: gallery assertions, not shipped UI.
// The GitHub page uses the pane's width (Leo, 2026-11-07: "it's just giving up way too much
// space"), and a table in a description keeps a short column's words whole: cmux#37993's check
// table stacked "Status" and "Passed" a letter a line beside a long Explanation column.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("github-page-width.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "../..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.github", { browser, timeoutMs: 120_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [760, 1200, 1600, 2200]) {
    test(`at ${width}px the page fills the pane and table words stay whole`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 1100 } });
      try {
        await page.goto(`${base}${galleryFrame("pages.github", { variant: "width-fill", reducedMotion: 1 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".gh-md table").waitFor();
        const layout = await page.evaluate(() => {
          const pane = document.querySelector(".gh")!.getBoundingClientRect().width;
          const head = document.querySelector(".gh-head")!.getBoundingClientRect().width;
          // Each Status cell's text, as the lines it draws on.
          const lines = [...document.querySelectorAll(".gh-md tr > :nth-child(2)")].map((cell) => {
            const range = document.createRange();
            range.selectNodeContents(cell);
            const tops = new Set([...range.getClientRects()].map((rect) => Math.round(rect.top)));
            return [cell.textContent, tops.size] as const;
          });
          return { pane, head, lines };
        });
        // Only a gutter of at most 24px a side is left.
        expect(layout.head).toBeGreaterThanOrEqual(layout.pane - 48);
        expect(layout.lines.length).toBe(6);
        for (const [text, count] of layout.lines) expect([text, count]).toEqual([text, 1]);
      } finally {
        await page.close();
      }
    });
  }
});
