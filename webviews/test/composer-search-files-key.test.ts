// Search Files… (in an agent chat, cx-ncc.69, Codex desktop app parity; no default key since Cmd-P is the native Go to, 2026-10-19): the app sends the
// page the `searchFiles` command, which opens the composer's file search with the keyboard in its
// field. The composer gallery's play sends it in Chromium; this checks the play passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-search-files-key.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-search-files-key: skipping (run `bunx playwright install chromium`)");
    describe.skip("Search Files key", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", { variant })}`);
    // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.waitForFunction(
      () => {
        const ready = document.documentElement.dataset.galleryReady;
        return ready === "1" || ready === "error";
      },
      undefined,
      { timeout: 90_000 },
    );
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

  test("the searchFiles command opens Search files with the keyboard in its field", async () => {
    const result = await play("search-files-key");
    expect(playFailures(result.report)).toEqual([]);
  });
});
