// The stacked Needs you and Ready for review lists share their leading mark and text columns.
// Read real layout in both themes and at narrow, normal and wide gallery widths.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("home-list-columns.test.ts", async () => {
  setDefaultTimeout(180_000);
  const entry = "agent-pane.home-lists";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "baseline" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [360, 560, 760]) {
    for (const colorScheme of ["light", "dark"] as const) {
      test(`${width}px ${colorScheme}: inbox and review share mark and text columns`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 1000 }, colorScheme });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          const frame = galleryFrame(entry, {
            variant: "baseline",
            colorScheme,
            frame: "component",
            width,
            height: 1000,
          });
          await page.goto(`http://127.0.0.1:${port}${frame}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          const columns = await page.evaluate(() => {
            const lefts = (selector: string) =>
              [...document.querySelectorAll(selector)].map((element) => element.getBoundingClientRect().left);
            return {
              width: document.querySelector(".home-lists-gallery")!.getBoundingClientRect().width,
              inboxMarks: lefts(".acpmux-home-inbox-mark"),
              inboxText: lefts(".acpmux-home-inbox-text"),
              reviewMarks: lefts(".acpmux-home-row > .acpmux-icon:first-child"),
              reviewText: lefts(".acpmux-home-row > .acpmux-home-title"),
            };
          });
          expect(columns.width).toBe(width);
          expect(columns.inboxMarks.length).toBeGreaterThan(0);
          expect(columns.reviewMarks.length).toBeGreaterThan(0);
          expect(columns.inboxText.length).toBeGreaterThan(0);
          expect(columns.reviewText.length).toBeGreaterThan(0);
          for (const x of [...columns.inboxMarks, ...columns.reviewMarks])
            expect(x).toBeCloseTo(columns.inboxMarks[0]!, 2);
          for (const x of [...columns.inboxText, ...columns.reviewText])
            expect(x).toBeCloseTo(columns.inboxText[0]!, 2);
        } finally {
          await page.close();
        }
      });
    }
  }
});
