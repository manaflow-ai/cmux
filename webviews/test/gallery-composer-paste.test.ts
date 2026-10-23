// The composer's paste gallery states (agent-pane.composer: image-attached, image-pasted-unnamed,
// image-failed, quick-image-attached, pdf-attached) paste a file into the prompt; text-pasted pastes
// a huge text. Each must reach its state with no page error: a stage that throws while it plays is
// a broken gallery entry, even when its picture still looks right. (Their play checks' layout-shift
// limits are another matter.)
//
// Before: the plays pasted a stand-in `{ files, types }` as clipboardData, which has no getData, so
// the prompt's paste handler (MarkdownField.tsx) threw "data.getData is not a function" on every
// paste. The plays now paste a real DataTransfer, as the browser does.
//
// Real Chromium from Playwright, on the gallery's dev server; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("gallery-composer-paste.test.ts", async () => {
  const VARIANTS = [
    "image-attached",
    "image-pasted-unnamed",
    "image-failed",
    "quick-image-attached",
    "pdf-attached",
    "text-pasted",
  ];
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("gallery-composer-paste: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer paste gallery states", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer", { variant, width: 760 })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of VARIANTS)
    test(`agent-pane.composer#${variant} pastes with no page error`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 900 } });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      for (;;) {
        try {
          await page.goto(url(variant));
          await page.waitForFunction(
            () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
            undefined,
            { timeout: 90_000 },
          );
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
      await page.close();
      expect(errors).toEqual([]);
      expect(ready).toBe("1");
    });
});
