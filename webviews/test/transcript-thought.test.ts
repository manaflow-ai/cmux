// A thought shows in full on its row, wrapped after a muted "Thought", with nothing to open and no
// tooltip (Leo 2026-10-13). The transcript gallery's plays check it in Chromium; this checks they
// passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-thought.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-thought: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript Thought row", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.transcript&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // Warm the gallery stage once before the test pages. The first load can trigger Vite's
    // dependency optimizer and reload its context while the real fixture is compiling; doing it
    // here keeps the measured plays from timing out on a cold runner.
    const warm = await browser.newPage({ viewport: { width: 760, height: 560 } });
    await warm.goto(stageURL("thought-row"));
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

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => {
      const ready = document.documentElement.dataset.galleryReady;
      return ready === "1" || ready === "error";
    });
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      searches: (
        window as unknown as { cmuxGalleryLog: { method: string; params?: { query?: string } }[] }
      ).cmuxGalleryLog
        .filter(({ method }) => method === "file.search")
        .map(({ params }) => params?.query),
    }));
    await page.close();
    return result;
  };

  test("a thought shows its full text on its row, with no tooltip", async () => {
    const result = await play("thought-row");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Find marks a word in a thought's text, not its Thought label", async () => {
    const result = await play("thought-find");
    expect(playFailures(result.report)).toEqual([]);
  });
});
