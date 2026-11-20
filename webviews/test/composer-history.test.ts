// ↑ in an empty agent chat prompt brings back the chat's earlier prompts, newest first, and ↓ steps
// forward to an empty prompt (Codex and Claude Code parity). A prompt being typed stays. The
// composer gallery's history-recall play presses the keys in the real prompt in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-history.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-history: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer history recall", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "history-recall" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const play = async (variant: string) => {
    const page = await browser!.newPage({
      viewport: { width: 760, height: 560 },
    });
    await page.goto(stageURL(variant));
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
    }));
    await page.close();
    return result;
  };

  test("↑ and ↓ in an empty prompt step through the chat's earlier prompts", async () => {
    const result = await play("history-recall");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("keeps prompt recall anchored when an older page arrives", async () => {
    const result = await play("history-recall-older-page");
    expect(playFailures(result.report)).toEqual([]);
  });
});
