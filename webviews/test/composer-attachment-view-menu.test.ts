// Leo, 2026-11-09: "In the right-click menu for the composer ... all attachments in line, or all
// attachments at the top like normal." The prompt's menu (Composer `fieldMenu`) offers both views
// of agentPane.attachmentView. Each gallery scene plays its own checks (composer.gallery.ts); a
// play that throws fails here. Real Chromium on the gallery stage; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-attachment-view-menu.test.ts", async () => {
  setDefaultTimeout(180_000);
  type PlayWindow = Window & { cmuxGalleryPlayReport?: { steps: { status: string }[] } };
  const ENTRY = "agent-pane.composer";
  const SCENES = [
    "attachments-menu-inline",
    "attachments-menu-picked-top",
    "attachments-menu-top-checked",
    "attachments-menu-picked-inline",
  ];
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("composer-attachment-view-menu: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer attachment view menu", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const scene of SCENES)
    test(`${scene} plays to its end`, async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      for (let attempt = 0; ; attempt += 1) {
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: scene })}`);
          await page.waitForFunction(
            () => {
              const root = document.documentElement.dataset;
              return root.galleryReady === "error" || (root.galleryReady === "1" && Boolean(root.galleryPlay));
            },
            undefined,
            { timeout: 120_000 },
          );
          break;
        } catch (error) {
          if (attempt > 1 || !/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      const state = await page.evaluate(() => ({
        ready: document.documentElement.dataset.galleryReady,
        play: document.documentElement.dataset.galleryPlay,
        failed: (window as PlayWindow).cmuxGalleryPlayReport?.steps.filter((step) => step.status === "fail"),
      }));
      expect({ scene, ready: state.ready, failed: state.failed, errors }).toEqual({
        scene,
        ready: "1",
        failed: [],
        errors: [],
      });
      expect(state.play).not.toBe("fail");
      await page.close();
    });
});
