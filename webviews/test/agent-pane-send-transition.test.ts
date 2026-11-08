// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-07: "when an attachment is inside of the composer, it's at a smaller size, and when it
// gets sent up, it gets slightly expanded just a bit. And that recalculation is jarring and it's
// jolting ... We need to be able to, like, know beforehand the size we're going to go for". A sent
// preview is laid out at its final size from its first frame (UserBubble.tsx sentImageSize), and the
// change from the composer's smaller chip is one move (conversation/sendMorph.ts): the preview's
// first frame is over the chip, then it goes to its slot. Through the move and the image's load the
// sent row keeps its height and the text beside the preview stays where it is. Every frame from the
// send is read: the agent pane's dev entry for a pasted screenshot (the composer's real send path),
// and gallery entry agent-pane.send-transition for a screen recording's tile.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-transition.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SCREEN_RECORDING_POSTER_JPEG } from "../src/gallery/fixtures/videoPoster";
import { galleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { left: number; top: number; width: number; height: number };
/// One frame of the sent row: its height, the preview's box and the bubble's box, in the viewport.
/// `bubble` is in the row's own coordinates: a chat that scrolls to the new prompt moves the row, not
/// its text within it. `moving`: the preview's copy over the pane draws it (sendMorph.ts).
type Frame = { at: number; row: number; preview?: Box; moving: boolean; hit: boolean; bubble?: Box; loaded: boolean };

await requireBrowserLane("agent-pane-send-transition.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-transition: skipping (run `bunx playwright install chromium`)");
    describe.skip("send transition", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let pane: Awaited<ReturnType<typeof createServer>> | undefined;
  let gallery: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await pane.listen();
    await warmViteServer(pane, "/");
    gallery = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await gallery.listen();
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
    await gallery?.close();
  });

  const POSTER = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;
  const port = (server: typeof pane) => (server!.httpServer!.address() as { port: number }).port;

  /// Reads the last sent row every frame from now for `ms`: its height, the box of the first element
  /// `preview` names in it and its bubble's box.
  const watchSentRow = async (page: Page, preview: string, ms = 1500) => {
    // The moving copy takes no clicks; here it must answer elementFromPoint for the paint check.
    await page.addStyleTag({ content: "[data-send-morph-ghost] { pointer-events: auto !important; }" });
    return page.evaluate(
      ({ preview, ms }) => {
        const frames: unknown[] = [];
        (window as unknown as { __sendFrames: unknown[] }).__sendFrames = frames;
        const box = (element: Element | null | undefined) => {
          if (!element) return undefined;
          const { left, top, width, height } = element.getBoundingClientRect();
          return { left, top, width, height };
        };
        const inRow = (row: Element, element: Element | null) => {
          const inner = box(element);
          if (!inner) return undefined;
          const outer = row.getBoundingClientRect();
          return { ...inner, left: inner.left - outer.left, top: inner.top - outer.top };
        };
        const start = performance.now();
        // raf-read: the move is the behavior; each frame's boxes are read as that frame is drawn,
        // its animations' current transforms included, so a frame after paint would skip the first.
        const tick = () => {
          const row = [...document.querySelectorAll(".cv-user")].at(-1);
          const shown = row?.querySelector(preview);
          const image = shown instanceof HTMLImageElement ? shown : shown?.querySelector("img");
          // What draws the preview: its copy over the pane while it moves (sendMorph.ts), else itself.
          const drawn = document.querySelector("[data-send-morph-ghost]") ?? shown;
          const drawnBox = box(drawn);
          // Painted, not only placed: the preview's center hits it, so nothing clips it.
          // Painted, not only placed: the preview's center hits it, or a moving copy (two previews'
          // paths may cross), never the composer under a clipped preview.
          const center =
            drawnBox &&
            document.elementFromPoint(drawnBox.left + drawnBox.width / 2, drawnBox.top + drawnBox.height / 2);
          const hit = !!center && (!!center.closest("[data-send-morph-ghost]") || !!shown?.contains(center));
          if (row && shown)
            frames.push({
              at: Math.round(performance.now() - start),
              row: row.getBoundingClientRect().height,
              preview: drawnBox,
              hit,
              moving: drawn !== shown,
              bubble: inRow(row, row.querySelector(".cv-user__bubble")),
              loaded: !!image && image.complete && image.naturalWidth > 0,
            });
          // raf-read: every frame of the move, as it is drawn (above).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __sendDone: boolean }).__sendDone = true;
        };
        (window as unknown as { __sendDone: boolean }).__sendDone = false;
        requestAnimationFrame(tick);
      },
      { preview, ms },
    );
  };
  /// The frames `watchSentRow` read, once its time is up.
  const sentFrames = async (page: Page) => {
    await page.waitForFunction(() => (window as unknown as { __sendDone: boolean }).__sendDone);
    return page.evaluate(() => (window as unknown as { __sendFrames: Frame[] }).__sendFrames);
  };

  const near = (a: Box | undefined, b: Box | undefined, label: string) => {
    expect(a, label).toBeDefined();
    expect(b, label).toBeDefined();
    for (const key of ["left", "top", "width", "height"] as const)
      expect(Math.abs(a![key] - b![key]), `${label} ${key}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`).toBeLessThan(
        1.5,
      );
  };

  /// The move: the first frame over the chip, the last in the slot, and from the first frame to past
  /// the image's load the row's height and the bubble's box never change.
  const expectOneMove = (frames: Frame[], chip: Box, label: string) => {
    expect(frames.length, `${label}: the sent row was never drawn`).toBeGreaterThan(2);
    const first = frames[0]!;
    const last = frames.at(-1)!;
    expect(last.loaded, `${label}: the preview never loaded`).toBe(true);
    near(first.preview, chip, `${label}: the preview's first frame is the chip`);
    expect(last.preview!.height, `${label}: the preview ends larger than its chip`).toBeGreaterThan(chip.height + 10);
    for (const frame of frames) {
      expect(frame.hit, `${label}: the preview is painted, not clipped, at ${frame.at} ms`).toBe(true);
      expect(frame.row, `${label}: the row's height at ${frame.at} ms`).toBe(first.row);
      if (first.bubble) near(frame.bubble, first.bubble, `${label}: the text beside it at ${frame.at} ms`);
    }
    // It lands where the preview is: the copy's last frame is the preview's first, no snap, even
    // while the chat scrolls to the new prompt.
    const landing = frames.findIndex((frame, index) => frame.moving && frames[index + 1]?.moving === false);
    expect(landing, `${label}: the move never landed`).toBeGreaterThanOrEqual(0);
    const [before, after] = [frames[landing]!.preview!, frames[landing + 1]!.preview!];
    for (const key of ["left", "top", "width", "height"] as const)
      expect(
        Math.abs(before[key] - after[key]),
        `${label}: the landing ${key}: ${JSON.stringify(before)} then ${JSON.stringify(after)}`,
      ).toBeLessThan(3);
  };

  /// The agent pane's dev entry with its in-page mock agent; the host answers `answers`' methods.
  const openPane = async (page: Page, answers: Record<string, unknown> = {}) => {
    await page.addInitScript((answers) => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: {
              postMessage: async ({ method }: { method: string }) => ({
                ok: true,
                value: answers[method.replace(/^cmux\.agent\./, "")] ?? null,
              }),
            },
          },
        },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, answers);
    await page.goto(`http://127.0.0.1:${port(pane)}/`);
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').waitFor();
  };

  /// A 1600x1000 screenshot pasted into the composer beside typed text, ready to send; answers the
  /// chip's box.
  const pasteScreenshot = async (page: Page): Promise<Box> => {
    await page.locator('.acpmux-composer-prompt [contenteditable="true"]').click();
    await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 1600;
      canvas.height = 1000;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      document
        .querySelector('.acpmux-composer-prompt [contenteditable="true"]')!
        .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    const chipImage = page.locator(".acpmux-composer .acpmux-attachment-image img").first();
    await chipImage.waitFor();
    await page.waitForFunction(() => {
      const image = document.querySelector<HTMLImageElement>(".acpmux-composer .acpmux-attachment-image img");
      return !!image && image.complete && image.naturalWidth > 0;
    });
    await page.keyboard.type(" what is this");
    const chip = await page
      .locator(".acpmux-composer .acpmux-attachment-image")
      .first()
      .evaluate((element) => {
        const { left, top, width, height } = element.getBoundingClientRect();
        return { left, top, width, height };
      });
    return chip;
  };

  const paneWithScreenshot = async (page: Page): Promise<Box> => {
    await openPane(page);
    return pasteScreenshot(page);
  };

  test("a pasted screenshot sent with text: its first frame is its chip, then it moves; the row and text never move", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      const chip = await paneWithScreenshot(page);
      await watchSentRow(page, "img.cv-user__image, .cv-user__image-placeholder");
      await page.keyboard.press("Enter");
      expectOneMove(await sentFrames(page), chip, "screenshot");
    } finally {
      await page.close();
    }
  });

  test("sent into a chat that scrolls: the screenshot follows its slot and lands with no snap", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await openPane(page);
      // Prompts and replies before it, so the chat overflows and scrolls to the new prompt.
      const prompt = page.locator('.acpmux-composer-prompt [contenteditable="true"]');
      for (const line of ["first question", "second question", "third question"]) {
        await prompt.click();
        await page.keyboard.type(line);
        await page.keyboard.press("Enter");
        await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
        const stop = page.getByRole("button", { name: "Stop" });
        await stop.waitFor({ state: "detached", timeout: 30_000 });
      }
      expect(
        await page.locator(".acpmux-scroll").evaluate((scroll) => scroll.scrollHeight > scroll.clientHeight + 200),
      ).toBe(true);
      const chip = await pasteScreenshot(page);
      await watchSentRow(page, "img.cv-user__image, .cv-user__image-placeholder");
      await page.keyboard.press("Enter");
      expectOneMove(await sentFrames(page), chip, "overflowing chat");
    } finally {
      await page.close();
    }
  });

  test("the moving screenshot is painted over the composer, not clipped or covered", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      const chip = await paneWithScreenshot(page);
      // Each new transform animation is held at its start: the frame drawn right after Enter.
      await page.evaluate(() => {
        const animate = Element.prototype.animate;
        Element.prototype.animate = function (...args: Parameters<typeof animate>) {
          const animation = animate.apply(this, args);
          animation.pause();
          animation.currentTime = 0;
          return animation;
        };
      });
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => document.getAnimations().some((animation) => animation.playState === "paused"));
      const shot = await page.screenshot({
        clip: { x: chip.left + 8, y: chip.top + 8, width: chip.width - 16, height: chip.height - 16 },
      });
      // The share of the chip's middle drawn in the screenshot's blue (#3a7bd5).
      const blue = await page.evaluate(async (png) => {
        const bytes = Uint8Array.from(atob(png), (char) => char.charCodeAt(0));
        const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
        const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
        const context = canvas.getContext("2d")!;
        context.drawImage(bitmap, 0, 0);
        const { data } = context.getImageData(0, 0, bitmap.width, bitmap.height);
        let hits = 0;
        for (let at = 0; at < data.length; at += 4)
          if (
            Math.abs(data[at]! - 0x3a) < 24 &&
            Math.abs(data[at + 1]! - 0x7b) < 24 &&
            Math.abs(data[at + 2]! - 0xd5) < 24
          )
            hits++;
        return hits / (data.length / 4);
      }, shot.toString("base64"));
      expect(blue, "the preview's first frame shows where its chip was").toBeGreaterThan(0.8);
    } finally {
      await page.close();
    }
  });

  test("a screenshot that names its source moves with its badge", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      await openPane(page, {
        "chat.attach.source": { sources: [{ name: "Screenshot", bundleId: "com.apple.screenshot.launcher" }] },
        "attachment.sourceIcon": {
          src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        },
      });
      await pasteScreenshot(page);
      await page.locator(".acpmux-composer .acpmux-source-badge").waitFor();
      // Each new transform animation is held at its start: the frame drawn right after Enter.
      await page.evaluate(() => {
        const animate = Element.prototype.animate;
        Element.prototype.animate = function (...args: Parameters<typeof animate>) {
          const animation = animate.apply(this, args);
          animation.pause();
          return animation;
        };
      });
      await page.keyboard.press("Enter");
      const ghost = page.locator("[data-send-morph-ghost]");
      await ghost.waitFor();
      expect(await ghost.locator(".acpmux-source-badge").count(), "the moving copy wears the source badge").toBe(1);
    } finally {
      await page.close();
    }
  });

  test("a screen recording pasted into the pane's composer: its tile moves with its poster, never a blank square", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      // The host reads the pasted recording (chat.attach.dropped, video.info), as the app does.
      await page.addInitScript((poster) => {
        Object.assign(window, {
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: async ({
                  method,
                  params,
                }: {
                  method: string;
                  params?: { offset?: number; data?: string };
                }) => {
                  const name = method.replace(/^cmux\.agent\./, "");
                  ((window as unknown as { __hostCalls: string[] }).__hostCalls ??= []).push(name);
                  if (name === "chat.attach.dropped")
                    return {
                      ok: true,
                      value: { items: [{ path: "/Users/you/Desktop/Recording.mov", folder: false }] },
                    };
                  // A pasted file is uploaded to where the chat runs (cloudUploads.ts).
                  if (name === "chat.upload.begin")
                    return { ok: true, value: { token: "t", size: 3, chunkSize: 65_536 } };
                  if (name === "chat.upload.chunk") return { ok: true, value: { offset: (params?.offset ?? 0) + 3 } };
                  if (name === "chat.upload.finish")
                    return { ok: true, value: { path: "/Users/you/Desktop/Recording.mov" } };
                  if (name === "video.info")
                    return {
                      ok: true,
                      value: {
                        durationMs: 12_400,
                        width: 1_920,
                        height: 1_080,
                        poster,
                        frames: [{ atMs: 0, data: poster.slice("data:image/jpeg;base64,".length) }],
                      },
                    };
                  return { ok: true, value: null };
                },
              },
            },
          },
          cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
          // acpmux's echo comes after the move: the tile is drawn from what the pane sent.
          cmuxAcpmuxMockSlowMethod: "session/prompt",
          cmuxAcpmuxMockSlowMs: 2_500,
        });
      }, POSTER);
      await page.goto(`http://127.0.0.1:${port(pane)}/`);
      const prompt = page.locator('.acpmux-composer-prompt [contenteditable="true"]');
      await prompt.waitFor();
      await prompt.click();
      await prompt.evaluate((target) => {
        const data = new DataTransfer();
        data.items.add(new File([new Uint8Array([0, 1, 2])], "Recording.mov", { type: "video/quicktime" }));
        target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      });
      const tile = page.locator(".acpmux-composer .acpmux-attachment-video");
      await page.waitForFunction(() => {
        const image = document.querySelector<HTMLImageElement>(".acpmux-composer .acpmux-attachment-video img");
        return !!image && image.complete && image.naturalWidth > 0;
      });
      await page.keyboard.type(" why does it flicker");
      const chip = await tile.first().evaluate((element) => {
        const { left, top, width, height } = element.getBoundingClientRect();
        return { left, top, width, height };
      });
      // Past acpmux's echo (2.5 s): the tile it draws is the one already on screen.
      await watchSentRow(page, ".cv-user__video", 3_500);
      await page.keyboard.press("Enter");
      const frames = await sentFrames(page);
      expectOneMove(frames, chip, "pasted recording");
      for (const frame of frames)
        expect(frame.loaded, `the tile draws its poster, not a blank square, at ${frame.at} ms`).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("a screen recording's tile: its first frame is its chip, then it moves; the row and text never move", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 520 } });
    try {
      await page.goto(
        `http://127.0.0.1:${port(gallery)}` +
          galleryFrame("agent-pane.send-transition", { variant: "move", width: 760, height: 520 }),
      );
      await page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""));
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
      const tile = page.locator('[data-gallery-chip="video"] .acpmux-attachment');
      await tile.waitFor();
      const chip = await tile.evaluate((element) => {
        const { left, top, width, height } = element.getBoundingClientRect();
        return { left, top, width, height };
      });
      await watchSentRow(page, ".cv-user__video");
      await page.locator("[data-send]").click();
      expectOneMove(await sentFrames(page), chip, "recording");
    } finally {
      await page.close();
    }
  });

  test("with motion off the preview draws in its slot from the first frame", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 520 } });
    try {
      await page.goto(
        `http://127.0.0.1:${port(gallery)}` +
          galleryFrame("agent-pane.send-transition", { variant: "move", width: 760, height: 520 }),
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
      await watchSentRow(page, ".cv-user__video");
      await page.locator("[data-send]").click();
      const frames = await sentFrames(page);
      expect(frames.length).toBeGreaterThan(2);
      for (const frame of frames) {
        near(frame.preview, frames.at(-1)!.preview, `the tile at ${frame.at} ms`);
        expect(frame.row).toBe(frames[0]!.row);
      }
    } finally {
      await page.close();
    }
  });
});
