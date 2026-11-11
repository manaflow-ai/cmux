// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// The image viewer opens below a one-tab pane's floating tab row, its name inside its own bar, and
// draws the image at full opacity over a light backdrop (Leo, 2026-11-05: "this screenshot preview
// has too much opacity and the file nameis also way at the top"). The gallery variant's play does
// the measuring (ImageViewer.gallery.ts `underTabRow`); this runs it in Chromium, both schemes. The chat's
// gallery opens over the pane the same way (GalleryDialog.gallery.ts `underTabRow`).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/image-viewer-tab-row-browser.test.ts
// CMUX_IMAGE_VIEWER_CAPTURE_DIR=<dir> keeps a still per scheme.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures, playNotice } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("image-viewer-tab-row-browser.test.ts", async () => {
  const CASES = [
    {
      entry: "agent-pane.image-viewer",
      variant: "pasted-screenshot-under-tab-row",
      name: "a pasted screenshot",
    },
    { entry: "agent-pane.chat-gallery", variant: "under-tab-row", name: "the chat's gallery" },
  ] as const;
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
    for (const { entry, variant } of CASES) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const { entry, variant, name } of CASES)
    for (const colorScheme of ["dark", "light"] as const)
      test(`${name} opens below the tab row (${colorScheme})`, async () => {
        const page = await browser!.newPage({
          viewport: { width: 760, height: 720 },
          colorScheme,
          deviceScaleFactor: 2,
        });
        try {
          const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
          await page.goto(base + galleryFrame(entry, { variant, colorScheme, width: 760, height: 720 }));
          await page.waitForFunction(() =>
            ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          );
          const report = await page.evaluate(() => ({
            ready: document.documentElement.dataset.galleryReady,
            play: JSON.stringify((window as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
          }));
          const captures = process.env.CMUX_IMAGE_VIEWER_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
          if (captures) {
            await mkdir(captures, { recursive: true });
            await page.screenshot({ path: path.join(captures, `${variant}-${colorScheme}.png`) });
          }
          expect(report.ready).toBe("1");
          // What the play did wrong, by name: its own checks (the viewer under the tab row, the name
          // outside its bar, a dimmed image), a step that did not run, a moved anchor, a layout shift,
          // and a covered, clipped or off-screen popup in any step (the Gallery dialog is graded as a
          // popup and its entry does not ask for the popup-layer check, so the stage only warns).
          // A frame over 33 ms or a slow settle times the shared CI runner as much as the page and
          // fails no behavior test (support/galleryPlay.ts); the notice still names it and its step.
          const notice = playNotice(`image-viewer-tab-row ${variant} ${colorScheme}`, report.play);
          if (notice) console.log(notice);
          expect(playFailures(report.play, "all")).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
