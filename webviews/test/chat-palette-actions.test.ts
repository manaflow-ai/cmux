// Agent chat palette actions (cx-ncc.72, Codex desktop app parity): the app sends the page
// `archiveChat` or reads `lastCodeBlock()`, and the page archives the chat the way its menu does
// or answers the latest reply's last code block. The transcript gallery's plays drive both in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-palette-actions.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-palette-actions: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat palette actions", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.transcript", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: { variant: "archive-chat-key" } });
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
    }));
    await page.close();
    return result;
  };

  test("Copy Last Code Block hands the app the latest reply's last code block", async () => {
    const result = await play("copy-last-code-block");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Archive Chat archives through the chat menu's host call", async () => {
    const result = await play("archive-chat-key");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Mark as Unread asks the host to mark the chat unread", async () => {
    const result = await play("mark-unread-menu");
    expect(playFailures(result.report)).toEqual([]);
  });
});
