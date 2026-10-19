// Settings opened at a Fonts row (`?focus=appearance.fonts.ui`, the gallery's `fonts` state) shows
// the group's live preview whole: centering the focused row scrolled the preview's top, and its
// first chat bubble, under the content's top edge in a short or narrow window. The first bubble's
// top and the preview card's top stay inside the visible content.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("settings-font-preview-reveal.test.ts", async () => {
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
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // The gallery's capture size, and short windows where centering the row has no room above it.
  test.each([
    [480, 760],
    [480, 560],
    [1000, 420],
  ])("at %ipx x %ipx the focused Fonts row shows the preview's first bubble whole", async (width, height) => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height } });
    await page.goto(
      `http://127.0.0.1:${port}/gallery/frame.html?entry=pages.settings&variant=fonts&frame=component&width=${width}&height=${height}`,
    );
    // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.locator("[data-font-preview]").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 30_000,
    });
    const box = await page.evaluate(() => {
      const top = (selector: string) => document.querySelector(selector)!.getBoundingClientRect().top;
      const focused = document.activeElement?.closest("[data-row-key]")?.getAttribute("data-row-key");
      return {
        content: top(".content"),
        card: top("[data-font-preview]"),
        bubble: top(".font-preview-user"),
        row: document.querySelector('[data-row-key="appearance.fonts.ui"]')!.getBoundingClientRect().bottom,
        bottom: document.querySelector(".content")!.getBoundingClientRect().bottom,
        focused,
      };
    });
    await page.close();
    expect(box.focused).toBe("appearance.fonts.ui");
    expect(box.card).toBeGreaterThanOrEqual(box.content);
    expect(box.bubble).toBeGreaterThan(box.card);
    // The focused row itself stays in view.
    expect(box.row).toBeLessThanOrEqual(box.bottom);
  });
});
