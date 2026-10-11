// Typing @ in the agent chat composer offers the chat's files (cx-ncc.68, Codex desktop app parity).
// The composer gallery's plays type into the real prompt in Chromium against the gallery host's
// `file.search` answer; this checks each play passed and what the page asked the host.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-mention.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-mention: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer @ mention", () => test("chromium", () => {}));
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

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=agent-pane.composer&variant=${variant}`);
    await page.waitForFunction(() => {
      const ready = document.documentElement.dataset.galleryReady;
      return ready === "1" || ready === "error";
    });
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      error: document.documentElement.dataset.galleryPlayError,
      searches: (
        window as unknown as { cmuxGalleryLog: { method: string; params?: { query?: string } }[] }
      ).cmuxGalleryLog
        .filter(({ method }) => method === "file.search")
        .map(({ params }) => params?.query),
    }));
    await page.close();
    return result;
  };

  test("@ then letters lists the chat's matching files and Return writes the path", async () => {
    const result = await play("mention-picker");
    expect(result.play, result.error).toBe("pass");
    expect(result.searches).toContain("rea");
  });

  test("an @ inside a word opens nothing and asks the host for nothing", async () => {
    const result = await play("mention-mid-word");
    expect(result.play, result.error).toBe("pass");
    expect(result.searches).toEqual([]);
  });
});
