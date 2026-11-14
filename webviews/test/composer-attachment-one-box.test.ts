// Leo, 2026-11-10: "the preview placeholder boxes are incongruent between the initial load, then the
// second load, and the chat attachment itself. the calculations are not right, and the loading may
// take too long... pasting it into the chat and all esp for screensharing vids should be a lot
// faster. it's 99% of the time fine for it to just to be a path and stuff, so idk why it's so slow"
//
// One box from paste to sent message. A screen recording (52 MB, a QuickTime movie whose `moov`
// comes after its media, as a recording's does) and a screenshot are pasted into a chat's composer
// on this Mac. Every animation frame from the paste samples the new attachment's box in the prompt.
// Then the prompt is sent, and the sent message's tile is read. It asserts:
// - the first box drawn is the last: no size change between the loading tile, the tile while the host
//   reads the video, and the chip with its poster;
// - the sent message's tile has the composer chip's shape (its height is the sent row's own);
// - the recording is a chip, in its final box and ready to send, within PASTE_TO_CHIP_MS of the paste,
//   while the host's read of the video (`video.info`, AVFoundation's poster, frames and probes)
//   takes VIDEO_INFO_MS: the chip is its path, and the read fills in behind it;
// - a send made right after the paste goes at once, not after that read.
//
// Each run prints one `one-box metrics` line (paste-to-chip, size changes, send wait, shapes): the
// before/after numbers of the PR come from it. The page is the pane's dev entry with the in-page
// mock transport, in both engines (CI fails the file when one cannot launch).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { x: number; y: number; width: number; height: number };
type Sample = { at: number; rect?: Rect; busy: boolean; poster: boolean };
type ProbeWindow = Window & {
  __files?: Record<string, File>;
  __probe?: {
    samples: Sample[];
    stop: boolean;
    before: Set<Element>;
    start: number;
  };
};

await requireBrowserLane("composer-attachment-one-box.test.ts", async () => {
  setDefaultTimeout(120_000);
  /// How long the mock host takes to read a pasted video (`video.info`, `video.frames`,
  /// `video.transcript`): a large recording's AVFoundation read, its scene probes and its speech.
  const VIDEO_INFO_MS = 1_500;
  /// The bound on paste to a chip in its final box, ready to send.
  const PASTE_TO_CHIP_MS = 400;
  /// The bound on a send made right after the paste, from its key press to the sent message's tile (a
  /// screenshot's, which waits for nothing, takes 450 to 650 ms of the send's own motion).
  const SEND_MS = 900;
  /// The recording's size on disk: past 50 MB, as a minute of screen recording is.
  const RECORDING_BYTES = 52 * 1024 * 1024;
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-attachment-one-box: ${name} did not launch`);
      console.warn(`composer-attachment-one-box: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("one attachment box", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: {
        port: 0,
        host: "127.0.0.1",
        strictPort: false,
        watch: { ignored: () => true },
      },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

  /// A chat on this Mac whose host knows where a pasted recording is (`chat.attach.dropped`) and
  /// reads it in VIDEO_INFO_MS (a 1920x1080 recording, 42 s long).
  async function newChat(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript((readMs) => {
      const later = <T>(value: T) =>
        // fixed-wait: the host's read time is the behavior measured (the chip must not wait on it).
        new Promise<T>((resolve) => setTimeout(() => resolve(value), readMs));
      const poster = () => {
        const canvas = document.createElement("canvas");
        canvas.width = 320;
        canvas.height = 180;
        const context = canvas.getContext("2d")!;
        context.fillStyle = "#2a5d9f";
        context.fillRect(0, 0, 320, 180);
        return canvas.toDataURL("image/jpeg");
      };
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: {
              postMessage: async ({ method, params }: { method: string; params?: { names?: string[] } }) => {
                const name = method.replace(/^cmux\.agent\./, "");
                if (name === "chat.attach.dropped") {
                  const names = params?.names ?? [];
                  return {
                    ok: true,
                    value: {
                      items: names.map((file) => ({
                        path: `/Users/you/Desktop/${file}`,
                        folder: false,
                      })),
                    },
                  };
                }
                if (name === "video.info") {
                  const src = poster();
                  return later({
                    ok: true,
                    value: {
                      durationMs: 42_000,
                      width: 1920,
                      height: 1080,
                      poster: src,
                      frames: [
                        {
                          atMs: 0,
                          data: src.slice("data:image/jpeg;base64,".length),
                        },
                      ],
                    },
                  });
                }
                if (name === "video.frames" || name === "video.transcript") return later({ ok: true, value: null });
                return { ok: true, value: null };
              },
            },
          },
        },
        // The worked mock chat: its folder is on this Mac, so a paste goes as its path.
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock" }),
        },
      });
    }, VIDEO_INFO_MS);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.locator(PROMPT).click();
    return page;
  }

  /// A QuickTime screen recording of RECORDING_BYTES, 1920x1080: `ftyp`, then its media (`mdat`),
  /// then `moov` with the movie header and one video track whose `tkhd` holds its size.
  const makeRecording = (page: Page, name: string) =>
    page.evaluate(
      ({ name, bytes }) => {
        const box = (type: string, ...parts: Uint8Array[]) => {
          const size = 8 + parts.reduce((sum, part) => sum + part.length, 0);
          const out = new Uint8Array(size);
          new DataView(out.buffer).setUint32(0, size);
          for (let at = 0; at < 4; at += 1) out[4 + at] = type.charCodeAt(at);
          let at = 8;
          for (const part of parts) {
            out.set(part, at);
            at += part.length;
          }
          return out;
        };
        const ftyp = box("ftyp", new TextEncoder().encode("qt  \0\0\0\0qt  "));
        // Movie header, version 0: 100 bytes of fields, timescale 600, 42 s.
        const mvhd = new Uint8Array(100);
        new DataView(mvhd.buffer).setUint32(12, 600);
        new DataView(mvhd.buffer).setUint32(16, 600 * 42);
        // Track header, version 0: the identity matrix at 40, width and height (16.16) at 76 and 80.
        const tkhd = new Uint8Array(84);
        const view = new DataView(tkhd.buffer);
        view.setUint32(0, 0x0000000f);
        view.setUint32(40, 0x00010000);
        view.setUint32(56, 0x00010000);
        view.setUint32(72, 0x40000000);
        view.setUint32(76, 1920 << 16);
        view.setUint32(80, 1080 << 16);
        const moov = box("moov", box("mvhd", mvhd), box("trak", box("tkhd", tkhd), box("mdia")));
        const media = bytes - ftyp.length - moov.length - 8;
        const head = new Uint8Array(8);
        new DataView(head.buffer).setUint32(0, media + 8);
        head.set([0x6d, 0x64, 0x61, 0x74], 4);
        const file = new File([ftyp, head, new Uint8Array(media), moov], name, {
          type: "video/quicktime",
        });
        const state = window as ProbeWindow;
        state.__files = { ...state.__files, [name]: file };
      },
      { name, bytes: RECORDING_BYTES },
    );

  /// A 2880x1800 screenshot-like PNG.
  const makeScreenshot = (page: Page, name: string) =>
    page.evaluate(async (name) => {
      const canvas = document.createElement("canvas");
      canvas.width = 2880;
      canvas.height = 1800;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, 2880, 1800);
      context.fillStyle = "#d6d7db";
      context.font = "28px sans-serif";
      for (let line = 0; line * 32 < 1800; line += 1) context.fillText(`line ${line}`, 24, 32 + line * 32);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const state = window as ProbeWindow;
      state.__files = {
        ...state.__files,
        [name]: new File([blob], name, { type: "image/png" }),
      };
    }, name);

  /// Samples, every frame from the paste, the new attachment's box in the prompt (its outer chip),
  /// whether it is still loading, and whether it draws its picture; then pastes `name`.
  const pasteAndProbe = (page: Page, name: string) =>
    page.evaluate(
      ({ name, prompt }) => {
        const composer = document.querySelector(".acpmux-composer-box")!;
        const chips = () => [
          ...composer.querySelectorAll(".acpmux-md-inline-chip, .acpmux-attachments .acpmux-attachment"),
        ];
        const probe = {
          samples: [] as Sample[],
          stop: false,
          before: new Set(chips()),
          start: performance.now(),
        };
        (window as ProbeWindow).__probe = probe;
        const sample = () => {
          if (probe.stop) return;
          const chip = chips().find((each) => {
            if (probe.before.has(each)) return false;
            const { width } = each.getBoundingClientRect();
            return width > 0 && getComputedStyle(each).visibility !== "hidden";
          });
          if (chip) {
            const { x, y, width, height } = chip.getBoundingClientRect();
            const picture = chip.querySelector<HTMLImageElement>("img:not(.acpmux-source-badge img)");
            probe.samples.push({
              at: performance.now() - probe.start,
              rect: { x, y, width, height },
              busy: chip.matches("[aria-busy='true']") || Boolean(chip.querySelector("[aria-busy='true']")),
              poster: Boolean(picture?.complete && picture.naturalWidth > 0),
            });
          } else
            probe.samples.push({
              at: performance.now() - probe.start,
              busy: true,
              poster: false,
            });
          // raf-read: the measurement is every frame from the paste until it settles.
          requestAnimationFrame(sample);
        };
        const data = new DataTransfer();
        data.items.add((window as ProbeWindow).__files![name]!);
        const field = document.querySelector(prompt)!;
        const paste = new ClipboardEvent("paste", {
          clipboardData: data,
          bubbles: true,
          cancelable: true,
        });
        // WebKit's constructor drops the clipboard; the app's paste route hands it on the same way.
        if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
        probe.start = performance.now();
        field.dispatchEvent(paste);
        // raf-read: the same sampling, from the paste's frame.
        requestAnimationFrame(sample);
      },
      { name, prompt: PROMPT },
    );

  const samples = (page: Page, stop = false) =>
    page.evaluate((stop) => {
      const probe = (window as ProbeWindow).__probe!;
      if (stop) probe.stop = true;
      return probe.samples;
    }, stop);

  /// Waits until the attachment drew its picture (the recording's poster, the screenshot's thumbnail)
  /// and a few frames past it.
  async function settle(page: Page) {
    await page
      .waitForFunction(
        () => {
          const probe = (window as ProbeWindow).__probe!;
          const last = probe.samples.at(-1);
          return Boolean(last?.poster && !last.busy);
        },
        undefined,
        { polling: 20, timeout: 30_000 },
      )
      .catch(async (error: unknown) => {
        // What the composer held when it never settled.
        const state = await page.evaluate(() => ({
          sizes: [
            ...new Set(
              (window as ProbeWindow).__probe!.samples.map((each) =>
                each.rect ? `${Math.round(each.rect.width)}x${Math.round(each.rect.height)} busy=${each.busy}` : "none",
              ),
            ),
          ],
          html: document.querySelector(".acpmux-composer-box")?.innerHTML.slice(0, 3000),
        }));
        console.log(`one-box unsettled ${JSON.stringify(state)}`);
        throw error;
      });
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let left = 10;
          // raf-read: waits out ten frames after the picture.
          const tick = () => (--left <= 0 ? resolve() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
    );
  }

  const size = (rect: Rect) => `${Math.round(rect.width)}x${Math.round(rect.height)}`;
  /// The distinct box sizes drawn, in order (a change is a new size).
  const sizes = (shown: Sample[]) =>
    shown.map((each) => size(each.rect!)).filter((each, index, all) => index === 0 || each !== all[index - 1]);

  /// The sent message's tile for the attachment: its box, and the time from Enter to its first frame.
  async function send(page: Page, selector: string) {
    await page.locator(PROMPT).click();
    await page.keyboard.press("End");
    await page.keyboard.type(" why does it flicker");
    const before = await page.locator(`.cv-user ${selector}`).count();
    const tile = page.locator(`.cv-user ${selector}`).nth(before);
    const start = Date.now();
    await page.keyboard.press("Enter");
    await tile.waitFor({ timeout: 15_000 });
    const sentMs = Date.now() - start;
    // Its first frames may still be in the send's motion: its box once it held still for ten frames.
    const rect = await tile.evaluate(
      (element) =>
        new Promise<{ x: number; y: number; width: number; height: number }>((resolve) => {
          let last = "";
          let still = 0;
          const tick = () => {
            const { x, y, width, height } = element.getBoundingClientRect();
            const now = `${x},${y},${width},${height}`;
            still = now === last ? still + 1 : 0;
            last = now;
            // raf-read: waits for the sent tile's box to hold still.
            if (still >= 10) resolve({ x, y, width, height });
            else requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        }),
    );
    return { sentMs, rect };
  }

  for (const [engine] of engines) {
    test(`${engine}: a pasted screen recording is one box from its first frame to the sent message, there at once`, async () => {
      const page = await newChat(engine);
      try {
        await makeRecording(page, "Screen Recording.mov");
        await pasteAndProbe(page, "Screen Recording.mov");
        // A send right after the paste, once the chip is there.
        await page.waitForFunction(() => Boolean((window as ProbeWindow).__probe!.samples.at(-1)?.rect), undefined, {
          polling: 10,
          timeout: 10_000,
        });
        const early = await samples(page);
        const firstRect = early.find((each) => each.rect)!;
        await page.waitForFunction(
          () => {
            const last = (window as ProbeWindow).__probe!.samples.at(-1);
            return Boolean(last?.rect && !last.busy);
          },
          undefined,
          { polling: 10, timeout: 30_000 },
        );
        const atReady = await samples(page);
        const ready = atReady.find((each) => each.rect && !each.busy)!;
        await settle(page);
        const shown = (await samples(page, true)).filter((each) => each.rect);
        const drawn = sizes(shown);
        const chip = shown.at(-1)!.rect!;
        const sent = await send(page, ".cv-user__video");
        const metrics = {
          case: `${engine} recording 52 MB`,
          firstChipMs: Math.round(firstRect.at),
          readyChipMs: Math.round(ready.at),
          posterMs: Math.round(shown.find((each) => each.poster)!.at),
          sizes: drawn,
          sizeChanges: drawn.length - 1,
          sendToSentMs: sent.sentMs,
          composerShape: +(chip.width / chip.height).toFixed(3),
          sentShape: +(sent.rect.width / sent.rect.height).toFixed(3),
        };
        console.log(`one-box metrics ${JSON.stringify(metrics)}`);
        expect(metrics.sizes).toHaveLength(1);
        expect(metrics.readyChipMs).toBeLessThan(PASTE_TO_CHIP_MS);
        expect(Math.abs(metrics.composerShape - metrics.sentShape)).toBeLessThan(0.03);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: a recording sent the moment it is pasted goes at once, not after the host's read`, async () => {
      const page = await newChat(engine);
      try {
        await makeRecording(page, "Screen Recording.mov");
        await pasteAndProbe(page, "Screen Recording.mov");
        await page.waitForFunction(
          () => {
            const last = (window as ProbeWindow).__probe!.samples.at(-1);
            return Boolean(last?.rect && !last.busy);
          },
          undefined,
          { polling: 10, timeout: 30_000 },
        );
        const sent = await send(page, ".cv-user__video");
        await samples(page, true);
        console.log(
          `one-box metrics ${JSON.stringify({ case: `${engine} recording send at once`, sendToSentMs: sent.sentMs })}`,
        );
        expect(sent.sentMs).toBeLessThan(SEND_MS);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: a pasted screenshot is one box from its first frame to the sent message`, async () => {
      const page = await newChat(engine);
      try {
        await makeScreenshot(page, "Screenshot.png");
        await pasteAndProbe(page, "Screenshot.png");
        await settle(page);
        const shown = (await samples(page, true)).filter((each) => each.rect);
        const drawn = sizes(shown);
        const chip = shown.at(-1)!.rect!;
        const sent = await send(page, "img.cv-user__image");
        const metrics = {
          case: `${engine} screenshot 2880x1800`,
          firstChipMs: Math.round(shown[0]!.at),
          readyChipMs: Math.round(shown.find((each) => !each.busy)!.at),
          sizes: drawn,
          sizeChanges: drawn.length - 1,
          sendToSentMs: sent.sentMs,
          composerShape: +(chip.width / chip.height).toFixed(3),
          sentShape: +(sent.rect.width / sent.rect.height).toFixed(3),
        };
        console.log(`one-box metrics ${JSON.stringify(metrics)}`);
        expect(metrics.sizes).toHaveLength(1);
        expect(Math.abs(metrics.composerShape - metrics.sentShape)).toBeLessThan(0.03);
      } finally {
        await page.close();
      }
    });
  }
});
