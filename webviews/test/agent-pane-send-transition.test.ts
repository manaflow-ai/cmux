// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// Leo, 2026-11-07: "when an attachment is inside of the composer, it's at a smaller size, and when it
// gets sent up, it gets slightly expanded just a bit. And that recalculation is jarring and it's
// jolting ... We need to be able to, like, know beforehand the size we're going to go for". And
// 2026-11-08 (ask-104c134b68): "I feel like there's some sort of, like, fly-in animation for when the
// images and attachments go from the composer to the, like, message display from the user or
// whatever. So I feel like that's kind of weird." A sent preview is laid out in its slot at its final
// size from its first frame (UserBubble.tsx sentImageSize) and appears there: it fades in with its
// prompt on the send motion (conversation.css SEND-ENTRANCE), never flying from the composer, and the
// composer's chip is gone in the same frame. Through the fade and the image's load the sent row keeps
// its height, and the preview and the text beside it keep their places in it. Every frame from the
// send is read, in the agent pane's dev entry (the composer's real send path).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-transition.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { SCREEN_RECORDING_POSTER_JPEG } from "../src/gallery/fixtures/videoPoster";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { left: number; top: number; width: number; height: number };
/// One frame of the sent row: its height, and the preview's and the bubble's boxes in the row's own
/// coordinates (a chat that rises to the new prompt moves the row, not what is in it). `opacity`: the
/// preview's drawn opacity (its own and every box's around it up to its row); `chips`: the composer's
/// attachments still drawn; `hit`: its own row draws at the preview's center, so nothing covers it.
type Frame = {
  at: number;
  row: number;
  preview: Box;
  bubble?: Box;
  opacity: number;
  chips: number;
  hit: boolean;
  loaded: boolean;
};

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
  let browser: Browser | undefined;
  beforeAll(async () => {
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await pane.listen();
    await warmViteServer(pane, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const POSTER = `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`;
  const port = (server: typeof pane) => (server!.httpServer!.address() as { port: number }).port;

  /// Reads the last sent row every frame from now for `ms`.
  const watchSentRow = (page: Page, preview: string, ms = 1500) =>
    page.evaluate(
      ({ preview, ms }) => {
        const frames: unknown[] = [];
        (window as unknown as { __sendFrames: unknown[] }).__sendFrames = frames;
        const inRow = (row: Element, element: Element | null) => {
          if (!element) return undefined;
          const inner = element.getBoundingClientRect();
          const outer = row.getBoundingClientRect();
          return {
            left: inner.left - outer.left,
            top: inner.top - outer.top,
            width: inner.width,
            height: inner.height,
          };
        };
        const start = performance.now();
        // raf-read: the send is the behavior; each frame is read as that frame is drawn.
        const tick = () => {
          const row = [...document.querySelectorAll(".cv-user")].at(-1);
          const shown = row?.querySelector(preview);
          if (row && shown) {
            const image = shown instanceof HTMLImageElement ? shown : shown.querySelector("img");
            let opacity = 1;
            const frame = row.closest(".acpmux-row");
            for (let at: Element | null = shown; at; at = at === frame ? null : at.parentElement)
              opacity *= Number(getComputedStyle(at).opacity);
            const box = shown.getBoundingClientRect();
            const center = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            // A row that rises to the new prompt comes out from behind the composer: there the
            // composer draws over it, as it should.
            const composer = document.querySelector(".acpmux-composer")?.getBoundingClientRect();
            const behind = !!composer && box.top + box.height / 2 >= composer.top;
            frames.push({
              at: Math.round(performance.now() - start),
              row: row.getBoundingClientRect().height,
              preview: inRow(row, shown),
              bubble: inRow(row, row.querySelector(".cv-user__bubble")),
              opacity,
              chips: document.querySelectorAll(".acpmux-composer .acpmux-attachment").length,
              // Its own row is what draws at its center (before its first draw the row answers for it).
              hit: behind || (!!center && row.contains(center)),
              loaded: !!image && image.complete && image.naturalWidth > 0,
            });
          }
          // raf-read: every frame of the send (above).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __sendDone: boolean }).__sendDone = true;
        };
        (window as unknown as { __sendDone: boolean }).__sendDone = false;
        requestAnimationFrame(tick);
      },
      { preview, ms },
    );
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

  /// In place: from its first frame the preview is in its slot at its final size, larger than its chip,
  /// and stays there; the row's height and the text beside it never change; the composer's chip is
  /// gone in that first frame; and the preview fades in (`fades`) or is drawn whole (motion off).
  const expectInPlace = (frames: Frame[], chip: Box, label: string, fades = true) => {
    expect(frames.length, `${label}: the sent row was never drawn`).toBeGreaterThan(2);
    const first = frames[0]!;
    const last = frames.at(-1)!;
    expect(last.loaded, `${label}: the preview never loaded`).toBe(true);
    expect(first.preview.height, `${label}: the preview is larger than its chip from its first frame`).toBeGreaterThan(
      chip.height + 10,
    );
    expect(first.chips, `${label}: the composer's chip is gone when the prompt appears`).toBe(0);
    for (const frame of frames) {
      near(frame.preview, first.preview, `${label}: the preview in its row at ${frame.at} ms`);
      expect(frame.row, `${label}: the row's height at ${frame.at} ms`).toBe(first.row);
      if (first.bubble) near(frame.bubble, first.bubble, `${label}: the text beside it at ${frame.at} ms`);
      expect(frame.hit, `${label}: the preview is painted, not covered, at ${frame.at} ms`).toBe(true);
      expect(frame.chips, `${label}: no chip comes back at ${frame.at} ms`).toBe(0);
    }
    if (fades) expect(first.opacity, `${label}: the preview fades in`).toBeLessThan(0.6);
    else expect(first.opacity, `${label}: with motion off it is drawn whole at once`).toBe(1);
    for (let index = 1; index < frames.length; index += 1)
      expect(frames[index]!.opacity, `${label}: the fade at ${frames[index]!.at} ms`).toBeGreaterThanOrEqual(
        frames[index - 1]!.opacity - 0.001,
      );
    expect(last.opacity, `${label}: the preview ends fully drawn`).toBeGreaterThan(0.99);
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

  test("a pasted screenshot sent with text appears in place at its size, fading in; nothing flies", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      const chip = await paneWithScreenshot(page);
      await watchSentRow(page, "img.cv-user__image, .cv-user__image-placeholder");
      await page.keyboard.press("Enter");
      expectInPlace(await sentFrames(page), chip, "screenshot");
    } finally {
      await page.close();
    }
  });

  test("sent into a chat that rises: the screenshot rises with its row, in place in it", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    try {
      await openPane(page);
      // Prompts and replies before it, so the chat overflows and rises to the new prompt.
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
      expectInPlace(await sentFrames(page), chip, "overflowing chat");
    } finally {
      await page.close();
    }
  });

  test("no copy of a sent attachment is drawn over the pane", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      await paneWithScreenshot(page);
      const before = await page.evaluate(() => document.querySelectorAll("img").length);
      await watchSentRow(page, "img.cv-user__image, .cv-user__image-placeholder", 400);
      await page.keyboard.press("Enter");
      await sentFrames(page);
      // The composer's chip went and the row's preview came: the same count of images, none extra.
      expect(await page.evaluate(() => document.querySelectorAll("img").length)).toBe(before);
    } finally {
      await page.close();
    }
  });

  test("a screenshot that names its source appears with its badge, in place", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      await openPane(page, {
        "chat.attach.source": { sources: [{ name: "Screenshot", bundleId: "com.apple.screenshot.launcher" }] },
        "attachment.sourceIcon": {
          src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        },
      });
      const chip = await pasteScreenshot(page);
      await page.locator(".acpmux-composer .acpmux-source-badge").waitFor();
      await watchSentRow(page, ".cv-user__sourced");
      await page.keyboard.press("Enter");
      expectInPlace(await sentFrames(page), chip, "sourced screenshot");
      expect(await page.locator(".cv-user .cv-user__sourced .acpmux-source-badge").count()).toBe(1);
    } finally {
      await page.close();
    }
  });

  test("a screen recording pasted into the pane's composer appears in place with its poster, never a blank square", async () => {
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
          // acpmux's echo comes later: the tile is drawn from what the pane sent.
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
      expectInPlace(frames, chip, "pasted recording");
      for (const frame of frames)
        expect(frame.loaded, `the tile draws its poster, not a blank square, at ${frame.at} ms`).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("with motion off the preview is drawn whole in its slot from the first frame", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      const chip = await paneWithScreenshot(page);
      await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
      await watchSentRow(page, "img.cv-user__image, .cv-user__image-placeholder");
      await page.keyboard.press("Enter");
      expectInPlace(await sentFrames(page), chip, "motion off", false);
    } finally {
      await page.close();
    }
  });
});
