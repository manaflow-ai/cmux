// Every transcript row keeps its chevron at one trailing column while a floating Copy action is
// revealed. The narrow viewport catches action text stealing the chevron's space.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-transcript-chevron-column.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-transcript-chevron-column: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.transcript-chevron-column", { browser, params: { variant: "shipped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [760, 420]) {
    test(`pins chevrons at the same x edge at ${width}px`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width, height: 300 } });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript-chevron-column", { variant: "shipped" })}`,
      );
      await page.locator("[data-chevron-column]").waitFor({ state: "attached" });
      const before = await page
        .locator("[data-chevron-column] .cv-tool__chevron")
        .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().right * 10) / 10));
      await page.locator('[data-label="copy"]').hover();
      const after = await page
        .locator("[data-chevron-column] .cv-tool__chevron")
        .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().right * 10) / 10));
      expect(new Set(before).size).toBe(1);
      expect(after).toEqual(before);
      await page.close();
    });
  }
});
