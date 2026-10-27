// Both composer looks use Codex's permission capsule; its padding belongs to the control,
// independent of the surrounding row's spacing. Measure the real gallery composer in Chromium.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-permission-pill.test.ts", async () => {
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

  for (const look of ["claude", "codex"] as const) {
    test(`${look}: permission control keeps the shared capsule geometry`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 360 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant: `${look}-chat` })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.waitForSelector(".acpmux-access-trigger");
      const measure = () =>
        page.$eval(".acpmux-access-trigger", (pill) => {
          const css = getComputedStyle(pill);
          const plus = document.querySelector(".acpmux-composer-plus .acpmux-icon")!;
          return {
            height: pill.getBoundingClientRect().height,
            paddingStart: Number.parseFloat(css.paddingInlineStart),
            paddingEnd: Number.parseFloat(css.paddingInlineEnd),
            radius: Number.parseFloat(css.borderTopLeftRadius),
            plusGap: pill.getBoundingClientRect().left - plus.getBoundingClientRect().right,
          };
        });
      const normal = await measure();
      expect(normal.height).toBe(28);
      expect(normal.paddingStart).toBe(8);
      expect(normal.paddingEnd).toBe(8);
      expect(normal.radius).toBeGreaterThanOrEqual(normal.height / 2);
      if (look === "codex") expect(normal.plusGap).toBe(16);
      await page.hover(".acpmux-access-trigger");
      expect(await measure()).toEqual(normal);
      await page.close();
    });
  }
});
