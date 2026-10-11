// The composer gallery's running-turn control is a real host interaction: Stop calls the pane
// bridge, and the host snapshot then restores Send. Exercise the fixture in a real Chromium page
// so the play cannot pass by only checking the static working screenshot.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { loadGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-send-stop.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-send-stop: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer Send/Stop", () => test("chromium", () => {}));
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("stops a running turn and restores Send after the host snapshot", async () => {
    const page: Page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await loadGalleryFrame(
      page,
      `http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer&variant=working-stop`,
    );

    const state = await page.evaluate(() => ({
      send: document.querySelector('button[aria-label="Send"]') !== null,
      stop: document.querySelector('button[aria-label="Stop"]') !== null,
      calls: (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.map(({ method }) => method),
      play: document.documentElement.dataset.galleryPlay,
    }));
    expect(state).toEqual({
      send: true,
      stop: false,
      calls: expect.arrayContaining(["chat.cancel"]),
      play: "pass",
    });
    await page.close();
  });
});
