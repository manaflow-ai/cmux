// cmux-web-test-timeout: 240
// The composer's model chip holds still as the person picks Cloud, a Mode and This Mac again (cmux#53226, the
// person: "we need to make sure that the model picker doesn't move around and stuff when i select cloud, change
// modes and stuff"). The play (cloudComposerChips.gallery.ts `modelHoldsStill`) samples the model chip's box every
// frame from This Mac at rest through each switch and throws on any frame where it moved by more than a pixel, or
// where the location strip's row moved; this opens it at full width, 760 px and 400 px in real Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-model-holds-still.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-model-holds-still: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer model holds still", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.cloud-composer-chips";
  const ENTRY_PATH = "src/agent-session/acpmux/cloudComposerChips.gallery.ts";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${ENTRY}&entryPath=${ENTRY_PATH}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const file of [ENTRY_PATH, "src/gallery/frame/component.tsx"])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} imports nothing; is it served?`);
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 760, height: 420 } });
    await warm.goto(stageURL("personal-default"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [label, width] of [
    ["full", 1100],
    ["760", 760],
    ["400", 400],
  ] as const)
    test(`at ${width} px the model chip stays put through Cloud, a Mode pick and This Mac again`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 420 } });
      try {
        await page.goto(stageURL(`model-holds-still-${label}`));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const report = await page.evaluate(
          () =>
            (window as Window & { cmuxGalleryPlayReport?: { status: string; error?: string } }).cmuxGalleryPlayReport,
        );
        // One short line per stage (lane-gh ci cuts long lines).
        console.log(`model-holds-still @${width}: ${report?.status} ${report?.error ?? ""}`.slice(0, 600));
        // The play throws when the model chip or the location row moves in any frame. The runner's own per-step
        // checks are not this test's: the Mode chip's chevron follows its label as "Auto" becomes "Bypass
        // permissions", and the play's per-frame sampling makes a long frame of its own.
        expect(report?.error).toBeUndefined();
        expect(report?.status).toBeDefined();
      } finally {
        await page.close();
      }
    });
});
