// A new chat's effort chip (Lawrence 2026-10-14, "we lost effort": the New Tab composer showed the
// model chip alone). Before a chat's session reports its options, the chip drew only a level a
// previous chat on that harness had remembered; a fresh profile or harness drew nothing. It names
// the level acpmux starts the harness on (`_acpmux/harnesses` start.effort).
// The composer gallery's play drives the real pane in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-chat-effort-chip.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-chat-effort-chip: skipping (run `bunx playwright install chromium`)");
    describe.skip("new chat effort chip", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a new chat names the level acpmux starts it on before its session reports", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    // Its own page (and browser context): no chip another play remembered.
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer&variant=new-chat-reasoning`);
    // A cold dev server compiles the gallery on the first request; give it longer than the default.
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    expect(playFailures(report)).toEqual([]);
  });
});
