// Stage hunk's key (cx-ncc.74): in Unstaged, n moves between changes and s stages the hunk it
// stopped at. The gallery's `agent-pane.diff-panel` `stage-hunk` play presses n, n, s and fails
// unless the source got the second hunk alone; this runs the play in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("changes-stage-hunk-keys.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("changes-stage-hunk-keys: skipping (run `bunx playwright install chromium`)");
    describe.skip("stage hunk keys", () => test("chromium", () => {}));
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
    // Warm the gallery stage once before the measured page, as composer-mention.test.ts does: the
    // first load can trigger Vite's dependency optimizer and reload its context mid-compile.
    const warm = await browser.newPage({ viewport: { width: 860, height: 620 } });
    await warm.goto(url());
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

  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.diff-panel&variant=stage-hunk`;

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("n then s stages the hunk n stopped at", async () => {
    const page = await browser!.newPage({ viewport: { width: 860, height: 620 } });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    // The play throws when s staged anything but the second hunk ("fail"); "warn" is a stage
    // measure (a scope menu's popup layer, a cold page's long frame), not the keys.
    expect(result.play === "pass" || result.play === "warn", result.report).toBe(true);
    expect(result.report).not.toContain('"error"');
  });
});
