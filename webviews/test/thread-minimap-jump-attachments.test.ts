// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A rail jump to a prompt that sent images lands on the top of its whole row, the images first, and
// stays there. Leo, 2026-10-25: "when I jump ... it jumps all the way up to the attachment area ...
// Then it just sends me back down to the, like, only the text area of the prompt". The jump's settle
// used to correct its landing from the text bubble below the images, so it reached the row's top (the
// images) and then slid down until the bubble sat at the landing line. Here the images answer late
// (their responses are held until the jump has come to rest) and wrap to a second line once they know
// their shapes, so the row re-measures after the landing: its top must not move on any frame.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { LANDING_OFFSET } from "../src/agent-session/acpmux/threadMinimap/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-jump-attachments.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const COUNT = 30;
  const TARGET = 8;
  /// Painted frames the landing must hold, its images not yet loaded, before their responses go out.
  const REST_FRAMES = 8;
  const paragraph = "The answer goes on for a while so the turn has real height in the transcript, as replies do.";
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  /// Wide screenshots with no size known up front: square slots until they load, then 192 px wide,
  /// so three no longer fit one line of the bubble's column and the row grows by a line.
  const images = (turn: number) =>
    [0, 1, 2].map((at) => ({ id: `shot-${turn}-${at}`, mimeType: "image/svg+xml", name: `shot-${at}.svg` }));
  const rows = Array.from({ length: COUNT }, (_, index) => [
    row(`t${index}-user`, "user", `Prompt number ${index + 1}: why does the sidebar overlap the toolbar here?`, {
      // The prompt jumped to, and the one above it, sent images.
      ...((index === TARGET || index === TARGET - 1) && { images: images(index) }),
    }),
    row(`t${index}-answer`, "assistant", Array.from({ length: 1 + (index % 4) * 2 }, () => paragraph).join("\n\n")),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 1_000 }),
  ]).flat();
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000"><rect width="1600" height="1000" fill="#345"/></svg>';

  describe("thread minimap jump to a prompt with images (Chromium)", () => {
    test("lands on the top of the images and holds there while they load and the row grows", async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
      await installPaintedFrames(page);
      // The images' responses wait on this until the jump has come to rest, however slow the renderer.
      let release!: () => void;
      const held = new Promise<void>((done) => (release = done));
      let served = 0;
      await page.route("**/late-image/**", async (route) => {
        await held;
        served += 1;
        await route.fulfill({ status: 200, contentType: "image/svg+xml", body: svg });
      });
      await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
      await page.waitForFunction(() => "__showRows" in window);
      await page.evaluate((shown) => {
        const probe = window as unknown as Record<string, unknown>;
        probe.__imageUrl = (id: string) => `${location.origin}/late-image/${id}.svg`;
        (probe.__showRows as (rows: unknown) => void)(shown);
      }, rows);
      await page.waitForSelector(".acpmux-minimap__tick");
      // At the chat's end, the prompt with images far above and never drawn.
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = scroller.scrollHeight;
        for (let frame = 0; frame < 10; frame += 1) await window.cmuxPaintFrame();
      });
      expect(await page.locator(`.acpmux-row[data-row-id="t${TARGET}-user"]`).count()).toBe(0);

      // Every painted frame from the click on: where the target row's images and bubble sit below the
      // transcript's top, and whether its images have drawn.
      await page.evaluate((target) => {
        const probe = window as unknown as Record<string, unknown>;
        const frames: { t: number; images?: number; bubble?: number; loaded: number }[] = [];
        probe.__frames = frames;
        window.cmuxAfterPaint(() => {
          const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
          const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="t${target}-user"]`);
          const strip = node?.querySelector<HTMLElement>(".cv-user__images")?.getBoundingClientRect();
          const bubble = node?.querySelector<HTMLElement>(".cv-user__bubble")?.getBoundingClientRect();
          frames.push({
            t: performance.now(),
            images: strip && strip.top - view.top,
            bubble: bubble && bubble.top - view.top,
            loaded: node?.querySelectorAll(".cv-user__images img").length ?? 0,
          });
          return frames.length < 600;
        });
      }, TARGET);
      const tick = await page.evaluate((at) => {
        const box = document.querySelector<HTMLElement>(`[data-tick="${at}"]`)!.getBoundingClientRect();
        return { x: box.left + 6, y: box.top + box.height / 2 };
      }, TARGET);
      await page.mouse.click(tick.x, tick.y);
      // The landing comes to rest: REST_FRAMES painted frames in a row with the row's images at one
      // place and none of them loaded (their responses are still held).
      const resting = (frames: { images?: number; loaded: number }[], count: number) =>
        frames.findIndex(
          (frame, index) =>
            frame.images !== undefined &&
            frames.slice(index, index + count).length === count &&
            frames.slice(index, index + count).every((later) => later.loaded === 0 && later.images === frame.images),
        );
      await page.waitForFunction((count) => {
        // The same check as `resting`, on the frames painted so far.
        const frames = (window as any).__frames as { images?: number; loaded: number }[];
        const last = frames.slice(-count);
        return (
          last.length === count &&
          last.every((frame) => frame.images !== undefined && frame.loaded === 0 && frame.images === last[0]!.images)
        );
      }, REST_FRAMES);
      expect(served).toBe(0);
      release();
      // Through the images' answer and a second (60 frames) after they have drawn.
      await page.waitForFunction(() => {
        const frames = (window as any).__frames as { loaded: number }[];
        const first = frames.findIndex((frame) => frame.loaded === 3);
        return first >= 0 && frames.length - first >= 60;
      });
      const frames = await page.evaluate(
        () => (window as any).__frames as { t: number; images?: number; bubble?: number; loaded: number }[],
      );
      await page.close();
      expect(served).toBeGreaterThanOrEqual(3);

      const loadedAt = frames.findIndex((frame) => frame.loaded === 3);
      // Where the jump came to rest, before any image answered: the row's own landing, not a read
      // taken after the row grew.
      const restAt = resting(frames, REST_FRAMES);
      expect(restAt).toBeGreaterThanOrEqual(0);
      expect(restAt + REST_FRAMES).toBeLessThanOrEqual(loadedAt);
      // Lands with the images' top at the landing line, the bubble below them.
      const rest = frames[restAt]!;
      expect(Math.abs(rest.images! - LANDING_OFFSET)).toBeLessThanOrEqual(1);
      expect(rest.bubble!).toBeGreaterThan(rest.images! + 100);
      // From the landing on, no frame moves the images' top: not a settle toward the bubble, not the
      // row growing a line when the images learn their shapes.
      const after = frames.slice(restAt);
      const off = after.filter((frame) => frame.images === undefined || Math.abs(frame.images - LANDING_OFFSET) > 1);
      expect(off.map((frame) => frame.images)).toEqual([]);
      // The row did grow (the images wrapped), so the hold was tested against a re-measure.
      const grown = frames[frames.length - 1]!;
      expect(grown.bubble! - grown.images!).toBeGreaterThan(rest.bubble! - rest.images! + 50);
    });
  });
});
