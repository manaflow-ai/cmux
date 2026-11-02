import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("handoff-content-font.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.handoff-review-message", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["Apple System Colors Light", "Apple System Colors"]) {
    test(`${theme}: handoff editors follow Chat Font Size without losing edits`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 1000 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.handoff-review-message", { variant: "draft", theme })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const review = page.locator(".acpmux-handoff-review");
        await review.locator("details").first().locator("summary").click();
        const editors = review.locator('textarea, input:not([type="checkbox"])');
        expect(await editors.count()).toBe(3);
        const context = editors.first();
        await context.fill("Keep this edited context when the font changes.");
        const originalValues = await editors.evaluateAll((elements) =>
          elements.map((element) => (element as HTMLInputElement).value),
        );
        const label = review.locator("label").first();
        const labelSize = await label.evaluate((element) => getComputedStyle(element).fontSize);
        for (const size of [14, 21, 28, 14]) {
          await page.evaluate(async (size) => {
            const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
            const { setChatDisplay } = await import(modulePath);
            setChatDisplay({ "agentPane.display.font.size": size });
          }, size);
          const sizes = await editors.evaluateAll((elements) =>
            elements.map((element) => parseFloat(getComputedStyle(element).fontSize)),
          );
          expect(sizes).toEqual([size, size, size]);
          expect(await label.evaluate((element) => getComputedStyle(element).fontSize)).toBe(labelSize);
          expect(
            await editors.evaluateAll((elements) => elements.map((element) => (element as HTMLInputElement).value)),
          ).toEqual(originalValues);
        }
      } finally {
        await page.close();
      }
    });
  }
});
