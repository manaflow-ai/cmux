// Attach Screenshot… and Attach Window… in the composer's + menu (cx-ncc.71, Codex desktop app
// parity): the host captures with macOS screencapture, saves the capture as taken in the chat's
// uploads within the click's one gesture, and answers a preview with the original's path; the page
// attaches both as one chip and never sends the bytes back. Either way, focus returns to the prompt.
// The composer gallery's plays answer the host call in Chromium, on a bridge stand-in that keeps the
// app's one-credit-per-gesture rule.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-capture.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-capture: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer capture", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
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

  test("the bridge stand-in gives one gesture credit per click", async () => {
    const result = await play("gesture-credit-once");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Attach Screenshot… attaches the host's region capture with its original's path, in one gesture", async () => {
    const result = await play("attach-screenshot");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("a cancelled Attach Window… attaches nothing", async () => {
    const result = await play("attach-window-cancelled");
    expect(playFailures(result.report)).toEqual([]);
  });
});
