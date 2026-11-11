// Leo, 2026-11-11: "this 3 stage attachment thing is still there". Leo, 2026-11-10: "the preview
// placeholder boxes are incongruent between the initial load, then the second load, and the chat
// attachment itself. the calculations are not right, and the loading may take too long... pasting it
// into the chat and all esp for screensharing vids should be a lot faster. it's 99% of the time fine
// for it to just to be a path and stuff". And before: "the placeholders should be right at the
// composer in and instant" (typing goes on around it, never displaced).
//
// One harness for the whole attach, from the paste to the sent message. In a chat on this Mac (the
// host knows the pasted file's path at once and takes 1.5 s to read a video, as a stand-in for its
// native read), it types "hello ", pastes a file, types "the" right away, and samples every frame
// until the attachment has its picture and then a second more. Then it sends. Per engine and file it
// reports, as one `ONE-STAGE-METRICS` line (and $FAST_CHECKS_OUT/one-stage-<engine>.json):
// - the time from the paste to the first box, to the ready chip and to its picture;
// - every distinct box the attachment was drawn in (one is one stage);
// - frames with a spinner in the box;
// - how far the typed "the" moved, in px, in the prompt;
// - the box's shape in the composer and in the sent message.
// Files: a 2880x1800 screenshot, a 50 MB screen recording (.mov, its moov after the media as a
// recording writes it) and a zip.
//
// The page is the pane's dev entry with the in-page mock transport. Both engines: the app's WebKit
// and Chromium; CI fails the file when one cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Kind = "image" | "bigImage" | "video" | "file";
type Sample = {
  at: number;
  box?: { width: number; height: number };
  state?: string;
  spinner: boolean;
  typed?: { x: number; y: number };
};
type Metrics = {
  engine: string;
  kind: Kind;
  bytes: number;
  pasteToFirstBoxMs: number | null;
  /// Painted frames after the paste's with no box yet: 0 is the chip in the paste's next frame.
  framesToFirstBox: number | null;
  /// When an image's header answered its size, from the paste (ms).
  headerAnsweredMs: number | null;
  /// The first frames' times from the paste (ms).
  frameTimes: number[];
  pasteToReadyMs: number | null;
  pasteToPictureMs: number | null;
  boxSizes: string[];
  boxSizeCount: number;
  states: string[];
  spinnerFrames: number;
  textDisplacementPx: number;
  composerRatio: number | null;
  sentRatio: number | null;
};
type ProbeWindow = Window & {
  __files?: Record<string, File>;
  __probe?: { samples: Sample[]; stop: boolean; pasteAt: number };
};

await requireBrowserLane("composer-attach-one-stage.test.ts", async () => {
  const FILES: Record<Kind, { name: string; type: string }> = {
    image: { name: "Screenshot 2026-11-10 at 4.20.01 PM.png", type: "image/png" },
    bigImage: { name: "Screenshot 2026-11-10 at 4.22.40 PM.png", type: "image/png" },
    video: { name: "Screen Recording 2026-11-10 at 4.21.16 PM.mov", type: "video/quicktime" },
    file: { name: "build-logs.zip", type: "application/zip" },
  };
  /// The stand-in host holds a video's read (poster, length) until the test lets it go, after the chip
  /// is ready: the native read's place, with no fixed wait.
  const RELEASE_VIDEO_READ = "one-stage-release-video-read";

  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-attach-one-stage: ${name} did not launch`);
      console.warn(`composer-attach-one-stage: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("one stage", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const results = new Map<string, Metrics>();
  const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

  async function newChat(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 700 } });
    await page.addInitScript(
      ({ release }) => {
        const ok = (value: unknown) => ({ ok: true, value });
        /// A 16:9 poster for the stand-in video read.
        const poster = () => {
          const canvas = document.createElement("canvas");
          canvas.width = 320;
          canvas.height = 180;
          const ink = canvas.getContext("2d")!;
          ink.fillStyle = "#3a5a8a";
          ink.fillRect(0, 0, 320, 180);
          return canvas.toDataURL("image/jpeg");
        };
        const reply = async (method: string, params: Record<string, unknown>) => {
          // The host's methods come as `cmux.agent.<name>`.
          switch (method.replace(/^cmux\.agent\./, "")) {
            case "chat.attach.dropped": {
              // A chat on this Mac: the host knows where the person's pasted files are, at once.
              const names = Array.isArray(params.names) ? (params.names as string[]) : [];
              return ok({ items: names.map((name) => ({ path: `/Users/dev/Desktop/${name}`, folder: false })) });
            }
            case "video.frames":
            case "video.transcript":
              return ok(null);
            case "video.info":
              // The stand-in for the host's native read: it answers when the test releases it.
              await new Promise((resolve) => window.addEventListener(release, resolve, { once: true }));
              return ok({ durationMs: 8_900, width: 1920, height: 1080, poster: poster(), frames: [] });
            default:
              return ok(null);
          }
        };
        Object.assign(window, {
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: (message: { method: string; params?: Record<string, unknown> }) =>
                  reply(message.method, message.params ?? {}),
              },
            },
          },
          cmuxAcpmuxActions: {
            // The worked mock chat: its folder is on this Mac, so a paste goes as its path.
            ready: async () => ({ protocolVersion: 1, transport: "mock" }),
          },
        });
      },
      { release: RELEASE_VIDEO_READ },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    // The chat is connected (its summary, so its folder on this Mac, is known) before the paste: a
    // chat on this Mac links a pasted file where it is.
    await page.waitForFunction(
      () => typeof (window as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions?.["chat.send"] === "function",
      undefined,
      { timeout: 30_000 },
    );
    await page.locator(PROMPT).click();
    return page;
  }

  /// Waits `count` painted frames.
  const frames = (page: Page, count: number) =>
    page.evaluate(
      (count) =>
        new Promise<void>((resolve) => {
          let left = count;
          // raf-read: waits out painted frames after the final state.
          const tick = () => (--left <= 0 ? resolve() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
      count,
    );

  /// Makes file `kind` in the page, kept as `window.__files[kind]`.
  const makeFile = (page: Page, kind: Kind) =>
    page.evaluate(
      async ({ kind, name, type }) => {
        let file: File;
        if (kind === "bigImage") {
          // About 10 MB: noise does not compress, as a photo-heavy 5K screenshot does not.
          const canvas = document.createElement("canvas");
          canvas.width = 2048;
          canvas.height = 1280;
          const ink = canvas.getContext("2d")!;
          const pixels = ink.createImageData(2048, 1280);
          for (let at = 0; at < pixels.data.length; at += 65_536)
            crypto.getRandomValues(pixels.data.subarray(at, at + 65_536));
          for (let at = 3; at < pixels.data.length; at += 4) pixels.data[at] = 255;
          ink.putImageData(pixels, 0, 0);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
          file = new File([blob], name, { type });
        } else if (kind === "image") {
          const canvas = document.createElement("canvas");
          canvas.width = 2880;
          canvas.height = 1800;
          const ink = canvas.getContext("2d")!;
          ink.fillStyle = "#1b1c20";
          ink.fillRect(0, 0, 2880, 1800);
          ink.fillStyle = "#d6d7db";
          ink.font = "28px sans-serif";
          for (let line = 0; line * 32 < 1800; line += 1) ink.fillText(`line ${line}`, 24, 32 + line * 32);
          const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
          file = new File([blob], name, { type });
        } else if (kind === "video") {
          // ftyp, a 50 MB mdat, then moov > trak > tkhd 1920x1080: a recording writes its moov last.
          const box = (tag: string, body: Uint8Array) => {
            const out = new Uint8Array(8 + body.length);
            new DataView(out.buffer).setUint32(0, out.length);
            for (let i = 0; i < 4; i += 1) out[4 + i] = tag.charCodeAt(i);
            out.set(body, 8);
            return out;
          };
          const ftyp = box("ftyp", new Uint8Array([113, 116, 32, 32, 0, 0, 0, 0, 113, 116, 32, 32]));
          const media = new Uint8Array(50 * 1024 * 1024);
          const mdatHead = new Uint8Array(8);
          new DataView(mdatHead.buffer).setUint32(0, media.length + 8);
          mdatHead.set([109, 100, 97, 116], 4);
          const tkhd = new Uint8Array(84);
          const view = new DataView(tkhd.buffer);
          view.setUint32(12, 1); // track id
          // The identity matrix (16.16 and 2.30 fixed point), then the size in 16.16.
          view.setUint32(40, 0x00010000);
          view.setUint32(56, 0x00010000);
          view.setUint32(72, 0x40000000);
          view.setUint32(76, 1920 << 16);
          view.setUint32(80, 1080 << 16);
          const moov = box("moov", box("trak", box("tkhd", tkhd)));
          file = new File([ftyp, mdatHead, media, moov], name, { type });
        } else {
          file = new File([new Uint8Array(200 * 1024).fill(7)], name, { type });
        }
        const state = window as ProbeWindow;
        state.__files = { ...state.__files, [kind]: file };
        return file.size;
      },
      { kind, ...FILES[kind] },
    );

  /// Samples every frame from the paste: the attachment's visible box (the chip's own tile inside the
  /// inline node, or a strip tile), its state, any spinner drawn in it, and where the first letter
  /// of the typed "the" is in the prompt.
  const startProbe = (page: Page) =>
    page.evaluate((prompt) => {
      const field = document.querySelector<HTMLElement>(prompt)!;
      const probe = { samples: [] as Sample[], stop: false, pasteAt: performance.now() };
      (window as ProbeWindow).__probe = probe;
      const visible = (element: Element, root: Element) => {
        const rect = element.getBoundingClientRect();
        if (rect.width < 1 || rect.height < 1) return false;
        for (let at: Element | null = element; at; at = at.parentElement) {
          const style = getComputedStyle(at);
          if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) < 0.02) return false;
          if (at === root) break;
        }
        return true;
      };
      const typed = () => {
        const walker = document.createTreeWalker(field, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const at = (node.textContent ?? "").lastIndexOf("the");
          if (at < 0) continue;
          const range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + 1);
          const rect = range.getBoundingClientRect();
          const origin = field.getBoundingClientRect();
          return { x: rect.left - origin.left, y: rect.top - origin.top };
        }
        return undefined;
      };
      const sample = () => {
        if (probe.stop) return;
        const box = document.querySelector(".acpmux-composer-box")!;
        const chip =
          [...box.querySelectorAll(".acpmux-md-inline-chip")].find((each) => visible(each, each)) ??
          [...box.querySelectorAll(".acpmux-attachments .acpmux-attachment")].find((each) => visible(each, each));
        const tile = chip?.querySelector(".acpmux-attachment") ?? chip;
        // Its box holding its place unseen counts as no box yet: nothing is drawn.
        const shown = tile && visible(tile, chip!) ? tile.getBoundingClientRect() : undefined;
        const spinner = chip
          ? [...chip.querySelectorAll('[class*="spinner"], .acpmux-paste-late[data-late] svg')].some((each) =>
              visible(each, chip),
            )
          : false;
        const where = typed();
        probe.samples.push({
          at: performance.now() - probe.pasteAt,
          ...(shown ? { box: { width: shown.width, height: shown.height } } : {}),
          ...(chip ? { state: chip.getAttribute("data-state") ?? "strip" } : {}),
          spinner,
          ...(where ? { typed: where } : {}),
        });
        // raf-read: the measurement is every frame from the paste until it settles.
        requestAnimationFrame(sample);
      };
      // raf-read: the same sampling, from the paste's frame.
      requestAnimationFrame(sample);
    }, PROMPT);

  const paste = (page: Page, kind: Kind) =>
    page.evaluate(
      ({ kind, prompt }) => {
        const data = new DataTransfer();
        data.items.add((window as ProbeWindow).__files![kind]!);
        const field = document.querySelector(prompt)!;
        const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        // WebKit's constructor drops the clipboard; the app's paste route hands it on the same way.
        if (event.clipboardData !== data) Object.defineProperty(event, "clipboardData", { value: data });
        (window as ProbeWindow).__probe!.pasteAt = performance.now();
        field.dispatchEvent(event);
      },
      { kind, prompt: PROMPT },
    );

  /// The attachment is final: its ready chip, with its picture drawn where it has one.
  const finished = (page: Page, kind: Kind) =>
    page.waitForFunction(
      (kind) => {
        const chip = document.querySelector('.acpmux-composer-box .acpmux-md-inline-chip[data-state="ready"]');
        if (!chip) return false;
        if (kind === "file") return true;
        const img = chip.querySelector<HTMLImageElement>("img");
        return Boolean(img?.complete && img.naturalWidth > 0);
      },
      kind,
      { polling: 10, timeout: 30_000 },
    );

  /// The sent message's attachment tile, once its size holds for ten frames.
  const sentBox = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<{ width: number; height: number } | null>((resolve) => {
          let last = "";
          let same = 0;
          const started = performance.now();
          const tick = () => {
            const bubbles = [...document.querySelectorAll(".cv-user")];
            const tile = bubbles
              .at(-1)
              ?.querySelector<HTMLElement>(
                ".cv-user__video, .cv-user__image-placeholder, .cv-user__inline-image img, img",
              );
            const rect = tile?.getBoundingClientRect();
            const key = rect && rect.width > 0 ? `${Math.round(rect.width)}x${Math.round(rect.height)}` : "";
            same = key && key === last ? same + 1 : 0;
            last = key;
            if (rect && same >= 10) return resolve({ width: rect.width, height: rect.height });
            if (performance.now() - started > 8_000) return resolve(null);
            // raf-read: waits for the sent tile's size to hold.
            requestAnimationFrame(tick);
          };
          // raf-read: from the send's frame.
          requestAnimationFrame(tick);
        }),
    );

  async function measure(engine: string, kind: Kind): Promise<Metrics> {
    const page = await newChat(engine);
    const bytes = await makeFile(page, kind);
    await page.keyboard.type("hello ");
    await startProbe(page);
    // ONE_STAGE_PROFILE=1: Chromium's CPU profile of the paste's first second, its top functions by
    // self time, to find what holds the main thread before the chip's first frame.
    const profiling = process.env.ONE_STAGE_PROFILE === "1" && engine === "chromium";
    const cdp = profiling ? await page.context().newCDPSession(page) : undefined;
    if (cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    await paste(page, kind);
    await page.keyboard.type("the");
    if (kind === "video") {
      // The chip is ready to send before the host has read the video: then the read lands.
      await page
        .waitForFunction(() => document.querySelector('.acpmux-composer-box .acpmux-md-inline-chip[data-state="ready"]'), undefined, {
          polling: "raf",
          timeout: 10_000,
        })
        .catch(() => {});
      await page.evaluate((release) => window.dispatchEvent(new Event(release)), RELEASE_VIDEO_READ);
    }
    if (cdp) {
      await frames(page, 30);
      const { profile } = (await cdp.send("Profiler.stop")) as {
        profile: {
          nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number } }[];
          samples: number[];
          timeDeltas: number[];
        };
      };
      const self = new Map<string, number>();
      const byId = new Map(profile.nodes.map((node) => [node.id, node]));
      profile.samples.forEach((id, index) => {
        const frame = byId.get(id)!.callFrame;
        const key = `${frame.functionName || "(anon)"} ${frame.url.replace(/^.*\/src\//, "src/").replace(/\?.*$/, "")}:${frame.lineNumber + 1}`;
        self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
      });
      const top = [...self].sort((a, b) => b[1] - a[1]).slice(0, 30);
      console.log(`ONE-STAGE-PROFILE ${kind}\n${top.map(([key, ms]) => `  ${ms.toFixed(1)} ms ${key}`).join("\n")}`);
    }
    let done = true;
    await finished(page, kind).catch(() => {
      done = false;
    });
    const headerAnsweredMs = await page.evaluate(() => {
      const mark = performance.getEntriesByName("acpmux:header-answered").at(-1);
      return mark ? Math.round(mark.startTime - (window as ProbeWindow).__probe!.pasteAt) : null;
    });
    const pictureAt = done
      ? await page.evaluate(() => performance.now() - (window as ProbeWindow).__probe!.pasteAt)
      : null;
    // A second of frames more after the final state: a late resize or poster counts too.
    await frames(page, 60);
    const samples = await page.evaluate(() => {
      const probe = (window as ProbeWindow).__probe!;
      probe.stop = true;
      return probe.samples;
    });
    const after = samples.filter((sample) => sample.at >= 0);
    const boxes = after.filter((sample) => sample.box);
    const firstBoxAt = after.findIndex((sample) => sample.box);
    const key = (box: { width: number; height: number }) => `${Math.round(box.width)}x${Math.round(box.height)}`;
    const boxSizes = [...new Set(boxes.map((sample) => key(sample.box!)))];
    const states = samples
      .map((sample) => sample.state ?? "none")
      .filter((state, index, all) => index === 0 || state !== all[index - 1]);
    const typed = samples.filter((sample) => sample.typed).map((sample) => sample.typed!);
    const textDisplacementPx = typed.length
      ? Math.max(...typed.map((at) => Math.max(Math.abs(at.x - typed.at(-1)!.x), Math.abs(at.y - typed.at(-1)!.y))))
      : -1;
    const first = boxes[0];
    const ready = samples.find((sample) => sample.state === "ready");
    const final = boxes.at(-1)?.box;
    const composerRatio = final ? final.width / final.height : null;
    let sentRatio: number | null = null;
    if (done && kind !== "file") {
      await page.locator(PROMPT).click();
      await page.keyboard.press("End");
      await page.keyboard.press("Enter");
      const sent = await sentBox(page);
      sentRatio = sent ? sent.width / sent.height : null;
    }
    await page.close();
    const metrics: Metrics = {
      engine,
      kind,
      bytes,
      pasteToFirstBoxMs: first ? Math.round(first.at) : null,
      headerAnsweredMs,
      frameTimes: after.slice(0, 8).map((sample) => Math.round(sample.at)),
      framesToFirstBox: firstBoxAt < 0 ? null : firstBoxAt,
      pasteToReadyMs: ready ? Math.round(ready.at) : null,
      pasteToPictureMs: pictureAt === null ? null : Math.round(pictureAt),
      boxSizes,
      boxSizeCount: boxSizes.length,
      states,
      spinnerFrames: samples.filter((sample) => sample.spinner).length,
      textDisplacementPx: Math.round(textDisplacementPx * 10) / 10,
      composerRatio: composerRatio === null ? null : Math.round(composerRatio * 1000) / 1000,
      sentRatio: sentRatio === null ? null : Math.round(sentRatio * 1000) / 1000,
    };
    console.log(`ONE-STAGE-METRICS ${JSON.stringify(metrics)}`);
    return metrics;
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    const out = process.env.FAST_CHECKS_OUT;
    if (out) {
      mkdirSync(out, { recursive: true });
      for (const [engine] of engines)
        writeFileSync(
          path.join(out, `one-stage-${engine}.json`),
          JSON.stringify(
            [...results.values()].filter((each) => each.engine === engine),
            null,
            2,
          ),
        );
    }
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const [engine] of engines)
    for (const kind of Object.keys(FILES) as Kind[])
      describe(`${engine} ${kind}`, () => {
      beforeAll(async () => {
        results.set(`${engine}/${kind}`, await measure(engine, kind));
      }, 120_000);
      const of = () => results.get(`${engine}/${kind}`)!;
      test(`${engine} ${kind}: the chip is there in the paste's next frame`, () => {
        expect(of().framesToFirstBox).toBe(0);
      });
      test(`${engine} ${kind}: one box from the paste to its picture`, () => {
        expect(of().boxSizes).toHaveLength(1);
      });
      test(`${engine} ${kind}: no spinner in the box`, () => {
        expect(of().spinnerFrames).toBe(0);
      });
      test(`${engine} ${kind}: the words typed after it never move`, () => {
        expect(of().textDisplacementPx).toBeGreaterThanOrEqual(0);
        expect(of().textDisplacementPx).toBeLessThanOrEqual(1);
      });
      test(`${engine} ${kind}: ready to send at once`, () => {
        expect(of().pasteToReadyMs).not.toBeNull();
        expect(of().pasteToReadyMs!).toBeLessThan(500);
      });
      if (kind !== "file")
        test(`${engine} ${kind}: the sent tile has the composer's shape`, () => {
          expect(of().sentRatio).not.toBeNull();
          expect(Math.abs(of().composerRatio! - of().sentRatio!)).toBeLessThan(0.02);
        });
      });
});
