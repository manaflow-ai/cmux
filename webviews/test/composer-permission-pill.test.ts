// Both composer looks use Codex's permission capsule; its padding belongs to the control,
// independent of the surrounding row's spacing. Since #26551 both looks draw it in the quiet row
// under the box, its shield under the + glyph. Measure the real gallery composer in Chromium.
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
          const shield = pill.querySelector(".acpmux-icon")!.getBoundingClientRect();
          const plusBox = plus.getBoundingClientRect();
          return {
            // Both looks put the capsule in the quiet row under the box (#26551), its shield under the
            // + glyph (composer-alignment-centers.test.ts).
            shieldUnderPlus: Math.abs((shield.left + shield.right) / 2 - (plusBox.left + plusBox.right) / 2) <= 0.5,
            height: pill.getBoundingClientRect().height,
            paddingStart: Number.parseFloat(css.paddingInlineStart),
            paddingEnd: Number.parseFloat(css.paddingInlineEnd),
            radius: Number.parseFloat(css.borderTopLeftRadius),
          };
        });
      const normal = await measure();
      expect(normal.height).toBe(28);
      expect(normal.paddingStart).toBe(8);
      expect(normal.paddingEnd).toBe(8);
      expect(normal.radius).toBeGreaterThanOrEqual(normal.height / 2);
      // Both looks pin the shield under the + glyph (composer-alignment-centers.test.ts): Codex's
      // lays the buttons out as Claude's (composerLook.ts).
      expect(normal.shieldUnderPlus).toBe(true);
      await page.hover(".acpmux-access-trigger");
      expect(await measure()).toEqual(normal);
      await page.close();
    });
  }
});
