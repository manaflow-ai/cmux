// Fork from any turn (cx-yqiv, Codex desktop app parity): a Claude or Codex chat's footer offers
// Fork under every completed turn, since acpmux forks those chats through any of them (cx-a7r);
// another agent forks only at a chat's end. The transcript gallery's plays drive both in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("turn-fork.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("turn-fork: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn fork", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: { variant: "fork-latest-turn-only" } });
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

  test("A Claude chat forks through an earlier turn from its footer", async () => {
    const result = await play("fork-any-turn");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("A Codex chat forks through an earlier turn from its footer", async () => {
    const result = await play("fork-any-turn-codex");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Another agent offers Fork only under its latest turn", async () => {
    const result = await play("fork-latest-turn-only");
    expect(playFailures(result.report)).toEqual([]);
  });
});
