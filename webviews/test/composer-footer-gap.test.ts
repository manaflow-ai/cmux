// The quiet footer sits under the shared composer card in both Claude and Codex harness sessions.
// Measure the real gallery geometry so a hover wash cannot add or remove vertical space.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-footer-gap.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["claude-chat", "goal-active"] as const) {
    test(`${variant}: footer gap stays 16px when its pill is hovered`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 360 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.waitForSelector(".acpmux-composer-foot .acpmux-model .acpmux-picker-button");
      const measure = () =>
        page.$eval(".acpmux-composer-foot .acpmux-model .acpmux-picker-button", (pill) => {
          const box = document.querySelector(".acpmux-composer-box")!;
          const card = box.getBoundingClientRect();
          const rect = pill.getBoundingClientRect();
          return {
            cardBottom: card.bottom,
            pillTop: rect.top,
            gap: rect.top - card.bottom,
            pillHeight: rect.height,
          };
        });
      const before = await measure();
      expect(before.gap).toBe(16);
      expect(before.pillHeight).toBe(28);
      await page.hover(".acpmux-composer-foot .acpmux-model .acpmux-picker-button");
      const after = await measure();
      expect(after).toEqual(before);
      await page.close();
    });
  }
});
