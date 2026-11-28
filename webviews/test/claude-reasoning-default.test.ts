// Claude's reasoning chip on the agent's own level (cx-ervhd, Leo 2026-10-13: a new chat read "Low"
// with nothing checked). A chat whose effort is "default" names the level that resolves to, the
// running model's default effort, even on a context variant id ("claude-opus-5-5[1m]"); the menu
// checks it with a Default hint, and Ultrathink (a prompt keyword) is not a level.
// Before its session reports, a new chat names the level acpmux starts it on, not nothing.
// The composer gallery's plays drive the real pane in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("claude-reasoning-default.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("claude-reasoning-default: skipping (run `bunx playwright install chromium`)");
    describe.skip("claude reasoning default", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // Each play gets its own page (and browser context): no chip a play remembers reaches the next.
  const play = async (variant: string) => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer&variant=${variant}`);
    // A cold dev server compiles the gallery on the first request; give it longer than the default.
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    return report;
  };

  test("the default level reads as the level it resolves to, checked, never Low", async () => {
    expect(playFailures(await play("reasoning-claude-default"))).toEqual([]);
  });

  // Lawrence 2026-10-14, "we lost effort": a New Tab chat showed the model chip alone.
  test("a new chat names the level acpmux starts it on before its session reports", async () => {
    expect(playFailures(await play("new-chat-reasoning"))).toEqual([]);
  });
});
