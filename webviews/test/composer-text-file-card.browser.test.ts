// A text file's card in the composer's strip (composer/TextAttachmentCard.tsx): its first lines from
// the top and its label pinned to the card's bottom, the lines taking all the room above it. The
// pasted text chip's rebuild (PastedTextChip.tsx) left this card as it was; review of #38350 (F1):
// the label lost its row and split the card's height with the lines.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-text-file-card.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-text-file-card: skipping (run `bunx playwright install chromium`)");
    describe.skip("text file card", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.text-attachment-card";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "file" } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [320, 560])
    test(`at ${width}px the label sits at the card's bottom and the lines fill the room above it`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: Math.max(width, 480), height: 600 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "file", width })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        const card = '.acpmux-attachment-pasted[data-text-kind="file"]';
        await page.waitForSelector(`${card} .acpmux-text-card__label`, { timeout: 60_000 });
        const box = await page.evaluate((selector) => {
          const chip = document.querySelector<HTMLElement>(selector)!;
          const body = chip.querySelector<HTMLElement>(".acpmux-attachment-pasted-open")!;
          const style = getComputedStyle(body);
          const inner = body.getBoundingClientRect();
          const top = inner.top + parseFloat(style.paddingTop);
          const bottom = inner.bottom - parseFloat(style.paddingBottom);
          const lines = chip.querySelector<HTMLElement>(".acpmux-text-card__lines")!.getBoundingClientRect();
          const label = chip.querySelector<HTMLElement>(".acpmux-text-card__label")!.getBoundingClientRect();
          return {
            top,
            bottom,
            linesTop: lines.top,
            linesBottom: lines.bottom,
            labelTop: label.top,
            labelBottom: label.bottom,
            labelHeight: label.height,
          };
        }, card);
        // The label is one caption row at the bottom, the lines everything from the top down to it.
        expect(Math.abs(box.labelBottom - box.bottom)).toBeLessThanOrEqual(1);
        expect(box.labelHeight).toBeLessThanOrEqual(15);
        expect(Math.abs(box.linesTop - box.top)).toBeLessThanOrEqual(1);
        expect(Math.abs(box.linesBottom - box.labelTop)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });
});
