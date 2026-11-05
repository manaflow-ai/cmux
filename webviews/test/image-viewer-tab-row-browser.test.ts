// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// The image viewer opens below a one-tab pane's floating tab row, its name inside its own bar, and
// draws the image at full opacity over a light backdrop (Leo, 2026-11-05: "this screenshot preview
// has too much opacity and the file nameis also way at the top"). The gallery variant's play does
// the measuring (ImageViewer.gallery.ts `underTabRow`); this runs it in Chromium, both schemes.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/image-viewer-tab-row-browser.test.ts
// CMUX_IMAGE_VIEWER_CAPTURE_DIR=<dir> keeps a still per scheme.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

const ENTRY = "agent-pane.image-viewer";
const VARIANT = "pasted-screenshot-under-tab-row";

await requireBrowserLane("image-viewer-tab-row-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const colorScheme of ["dark", "light"] as const)
    test(`a pasted screenshot opens below the tab row at full opacity (${colorScheme})`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 720 }, colorScheme, deviceScaleFactor: 2 });
      try {
        const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
        await page.goto(base + galleryFrame(ENTRY, { variant: VARIANT, colorScheme, width: 760, height: 720 }));
        await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
        const report = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady,
          play: (
            window as {
              cmuxGalleryPlayReport?: { status: string; error?: string; steps: { problems: string[] }[] };
            }
          ).cmuxGalleryPlayReport,
        }));
        const captures = process.env.CMUX_IMAGE_VIEWER_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
        if (captures) {
          await mkdir(captures, { recursive: true });
          await page.screenshot({ path: path.join(captures, `image-viewer-tab-row-${colorScheme}.png`) });
        }
        expect(report.ready).toBe("1");
        expect(report.play?.error ?? "").toBe("");
        expect(report.play?.steps.flatMap((step) => step.problems) ?? []).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
