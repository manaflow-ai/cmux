// The composer gallery's running-turn control is a real host interaction: Stop calls the pane
// bridge, and the host snapshot then restores Send. Exercise the fixture in a real Chromium page
// so the play cannot pass by only checking the static working screenshot.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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

  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.composer&variant=working-stop`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // One throwaway load of the same stage first. Cold, beside the parallel test batch, compiling
    // the stage (every gallery entry file, then the dependency optimizer, which reloads the page
    // when it finishes mid-load) took longer than the checked page's wait. This load waits it out
    // and loads every module the stage uses, its lazy imports included; the checked page below
    // then measures the play alone.
    const warm = await browser.newPage({ viewport: { width: 760, height: 560 } });
    await warm.goto(stageURL());
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        // An optimizer reload destroys the page's context; wait for the reloaded stage.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("stops a running turn and restores Send after the host snapshot", async () => {
    const page: Page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(stageURL());
    // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.waitForFunction(
      () => {
        const ready = document.documentElement.dataset.galleryReady;
        return ready === "1" || ready === "error";
      },
      undefined,
      { timeout: 90_000 },
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
