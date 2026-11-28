// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { belowMinimum, formatPair, readContrast } from "./support/contrastWalk";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { galleryStageServer, type GalleryStageServer } from "./support/galleryStageServer";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("kit-panel-contrast-browser.test.ts", async () => {
  let browser: Browser;
  let server: GalleryStageServer;
  const entry = "kit.primitives";
  const variant = "pieces";

  beforeAll(async () => {
    browser = await chromium.launch();
    server = await galleryStageServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      warm: (vite) => warmGalleryFrame(vite, entry, { browser, params: { variant } }),
    });
  }, 180_000);

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const colorScheme of ["light", "dark"] as const) {
    test(`both Panel titles are readable on a ${colorScheme} gallery page`, async () => {
      const page = await browser.newPage({ colorScheme });
      try {
        const frame = new URL(galleryFrame(entry, { variant, colorScheme }), server.origin);
        frame.pathname = server.framePath;
        await page.goto(frame.href);
        await page.locator('[data-gallery-ready="1"]').waitFor({ state: "attached" });
        for (const scheme of ["light", "dark"]) {
          const within = `[data-scheme="${scheme}"] .ui-surface-title`;
          const lines = await readContrast(page, { within, icons: false });
          expect(lines.map((line) => line.text)).toEqual(["Panel"]);
          expect(belowMinimum(lines).map(formatPair)).toEqual([]);
        }
      } finally {
        await page.close();
      }
    }, 90_000);
  }
});
