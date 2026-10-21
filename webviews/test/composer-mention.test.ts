// Typing @ in the agent chat composer offers other chats and the chat's folders and files (cx-ncc.68,
// Codex and Claude desktop app parity).
// The composer gallery's plays type into the real prompt in Chromium against the gallery host's
// `file.search` answer; this checks each play passed and what the page asked the host.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
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
    // Warm the gallery stage once before the test pages. The first load can trigger Vite's
    // dependency optimizer and reload its context while the real fixture is compiling; doing it
    // here keeps the measured plays from timing out on a cold runner.
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "mention-picker" } });
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
    expect(playFailures(result.report)).toEqual([]);
    expect(result.searches).toContain("rea");
  });

  test("after picking a path markdown escapes, typing on leaves the picker closed", async () => {
    const result = await play("mention-escaped-path");
    expect(playFailures(result.report)).toEqual([]);
    expect(result.searches).toEqual(["ini"]);
  });

  test("@proje lists other chats, then folders, then the chat folder's files", async () => {
    const result = await play("mention-mixed");
    expect(playFailures(result.report)).toEqual([]);
    expect(result.searches).toContain("proje");
  });

  test("picking another chat writes its title and full id", async () => {
    const result = await play("mention-session-pick");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("a chat named for a long prompt does not take @app from the file", async () => {
    const result = await play("mention-file-over-prompt-chat");
    expect(playFailures(result.report)).toEqual([]);
    expect(result.searches).toContain("app");
  });

  test("a bare @ lists the most recent other chats", async () => {
    const result = await play("mention-recent-chats");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("an @ inside a word opens nothing and asks the host for nothing", async () => {
    const result = await play("mention-mid-word");
    expect(playFailures(result.report)).toEqual([]);
    expect(result.searches).toEqual([]);
  });
});
