// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-11-07: "when an image or when an attachment is inside of the composer, it's at a
// smaller size, and when it gets sent up, it gets slightly expanded just a bit. And that
// recalculation is jarring ... We want to just be able to, like, know what we're going to send as
// for the size, and we just stick with that and then we just send it" ... "we don't want to have
// the inner elements jolt with previews or whatever."
//
// The real pane: paste a wide image (640x400) and a small one (100x60), type a line, press Enter,
// and read every painted frame from the send until the turn settles: each sent tile's box, the
// bubble's box and the transcript row's height. From the first frame a tile is drawn, none of
// them changes size (within half a pixel), and each tile is its image's own sent shape (never the
// square a size not yet known draws).
//
// The page is the pane's dev entry with the in-page mock transport. Real Chromium from Playwright;
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/sent-attachment-size-at-send.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";
import { SENT_IMAGE } from "../src/agent-session/acpmux/transcriptSelectors";

type Box = { width: number; height: number };
type Frame = { tiles: Box[]; bubble?: Box; row?: number };
type ProbeWindow = Window & { __frames?: Frame[] };

await requireBrowserLane("sent-attachment-size-at-send.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("sent attachment size at send", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
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

  async function newChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// Pastes a `width` x `height` PNG into the prompt.
  const paste = (page: Page, width: number, height: number, color: string) =>
    page.evaluate(
      async ({ COMPOSER_EDITOR, width, height, color }) => {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const context = canvas.getContext("2d")!;
        context.fillStyle = color;
        context.fillRect(0, 0, width, height);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        const data = new DataTransfer();
        data.items.add(new File([blob], `Screenshot ${width}x${height}.png`, { type: "image/png" }));
        document
          .querySelector(COMPOSER_EDITOR)!
          .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { COMPOSER_EDITOR, width, height, color },
    );

  test("a prompt sent with a wide and a small image keeps every box from its first frame", async () => {
    const page = await newChat();
    try {
      const prompt = page.locator(COMPOSER_EDITOR);
      await prompt.click();
      await paste(page, 640, 400, "#3a7bd5");
      await paste(page, 100, 60, "#d53a7b");
      // Both thumbnails drawn in the composer: their sizes are known before the send.
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-attachment-image img").length >= 2,
        undefined,
        {
          timeout: 15_000,
        },
      );
      await page.keyboard.type("what are these two");
      // From here, every painted frame: the sent prompt's tiles (a placeholder or the image), its
      // bubble and its row.
      await page.evaluate((sentImage) => {
        const frames: Frame[] = [];
        (window as ProbeWindow).__frames = frames;
        const size = (element: Element) => {
          const rect = element.getBoundingClientRect();
          return { width: Math.round(rect.width * 2) / 2, height: Math.round(rect.height * 2) / 2 };
        };
        window.cmuxAfterPaint(() => {
          const user = document.querySelector(".cv-user");
          if (!user) return void frames.push({ tiles: [] });
          const tiles = [
            ...user.querySelectorAll(`.cv-user__image-placeholder, ${sentImage}, .cv-user__image-failed`),
          ].map(size);
          const bubble = user.querySelector(".cv-user__bubble");
          const row = user.closest(".acpmux-row");
          frames.push({
            tiles,
            bubble: bubble ? size(bubble) : undefined,
            row: row ? Math.round(row.getBoundingClientRect().height * 2) / 2 : undefined,
          });
        });
      }, SENT_IMAGE);
      await page.keyboard.press("Enter");
      await page.locator(SENT_IMAGE).nth(1).waitFor({ timeout: 15_000 });
      // The turn runs to its end, and some frames more.
      const stop = page.getByRole("button", { name: "Stop" });
      await stop.waitFor({ state: "detached", timeout: 30_000 }).catch(() => {});
      for (let frame = 0; frame < 20; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      const frames = await page.evaluate(() => (window as ProbeWindow).__frames!);
      const drawn = frames.filter((frame) => frame.tiles.length === 2);
      console.log(
        `sent-attachment-size-at-send: ${drawn.length} frames with both tiles; distinct:`,
        JSON.stringify({
          tiles: [...new Set(drawn.map((frame) => JSON.stringify(frame.tiles)))],
          bubble: [...new Set(drawn.map((frame) => JSON.stringify(frame.bubble)))],
          row: [...new Set(drawn.map((frame) => frame.row))],
          firstFrames: frames.filter((frame) => frame.tiles.length > 0).slice(0, 4),
        }),
      );
      expect(drawn.length).toBeGreaterThan(5);
      // No frame draws one tile without the other.
      expect(frames.filter((frame) => frame.tiles.length === 1)).toEqual([]);
      const first = drawn[0]!;
      // Each tile is its image's own sent shape from its first frame: 640x400 at 160 tall is
      // 256x160; 100x60 is never magnified.
      expect(first.tiles).toEqual([
        { width: 256, height: 160 },
        { width: 100, height: 60 },
      ]);
      const near = (a: number | undefined, b: number | undefined) =>
        a !== undefined && b !== undefined && Math.abs(a - b) <= 0.5;
      const moved = drawn.filter(
        (frame) =>
          frame.tiles.some(
            (tile, index) =>
              !near(tile.width, first.tiles[index]!.width) || !near(tile.height, first.tiles[index]!.height),
          ) ||
          !near(frame.bubble?.width, first.bubble?.width) ||
          !near(frame.bubble?.height, first.bubble?.height) ||
          !near(frame.row, first.row),
      );
      expect({ first, moved }).toEqual({ first, moved: [] });
    } finally {
      await page.close();
    }
  });
});
