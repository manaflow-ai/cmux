// Leo, 2026-11-08, with two macOS screen recordings (.mov, 12 s at 576x144 and 20 s at 636x468):
// "there was a problem loading thse two videos together in the composer for some reason i added one
// after the other really quickly and the whole thing lagged/froze?"
//
// Two recordings pasted back to back, the host answering each as the app does: `chat.attach.dropped`
// with their paths, `video.info` (a poster, four key frames, the probes), `video.frames` (up to 16
// JPEGs at the recording's size) and `video.transcript`, each after the time the app takes. The
// page's main thread is timed from the first paste until every read has landed: its longest stall
// (a 4 ms heartbeat) and the time its long tasks took. Typing goes on meanwhile and must land.
//
// The page is the pane's dev entry with the in-page mock transport, in both engines (CI fails the
// file when one cannot launch). WebKit has no long-task record: there the heartbeat is the number.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-two-videos-browser.test.ts", async () => {
  /// The longest the main thread may stall while the two recordings attach and are read.
  const MAX_STALL_MS = 120;
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
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-two-videos-browser: ${name} did not launch`);
      console.warn(`composer-two-videos-browser: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("two videos at once", () => test("browsers", () => {}));
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

  type Video = { name: string; width: number; height: number; seconds: number };
  /// The two recordings Leo attached, and two full-screen Retina recordings (their frames 1280 px
  /// wide, several hundred KB each), the largest answers the host gives.
  const SETS: [string, Video[]][] = [
    [
      "Leo's two recordings",
      [
        {
          name: "Screen Recording 2026-11-08 at 10.01.12.mov",
          width: 576,
          height: 144,
          seconds: 12,
        },
        {
          name: "Screen Recording 2026-11-08 at 10.01.40.mov",
          width: 636,
          height: 468,
          seconds: 20,
        },
      ],
    ],
    [
      "two Retina recordings",
      [
        {
          name: "Screen Recording 2026-11-08 at 11.00.00.mov",
          width: 3456,
          height: 2234,
          seconds: 30,
        },
        {
          name: "Screen Recording 2026-11-08 at 11.00.30.mov",
          width: 3456,
          height: 2234,
          seconds: 45,
        },
      ],
    ],
  ];

  /// A chat whose host answers as the app does, after the time each read takes there.
  async function newChat(engine: string, videos: Video[]): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((videos) => {
      type Video = (typeof videos)[number];
      const state = window as unknown as {
        calls: { method: string; at: number; bytes: number }[];
        jpegs: Map<string, string[]>;
        pending: number;
      };
      state.calls = [];
      state.pending = 0;
      // fixed-wait: the host's read time is the behavior measured (the page must not stall on it).
      const after = <T>(ms: number, value: T) => new Promise<T>((resolve) => setTimeout(() => resolve(value), ms));
      const video = (src: unknown): Video | undefined => videos.find((v) => String(src).endsWith(v.name));
      /// `count` JPEGs of `video` at most `side` on a side: a screen's text, as noise, so each is as
      /// large as a real recording's frame (made once, before anything is timed).
      const jpegs = (v: Video, side: number, count: number) => {
        const key = `${v.name}:${side}:${count}`;
        const made = state.jpegs?.get(key);
        if (made) return made;
        const scale = Math.min(1, side / Math.max(v.width, v.height));
        const canvas = document.createElement("canvas");
        canvas.width = Math.round(v.width * scale);
        canvas.height = Math.round(v.height * scale);
        const context = canvas.getContext("2d")!;
        const out: string[] = [];
        for (let index = 0; index < count; index += 1) {
          const noise = context.createImageData(canvas.width, canvas.height);
          for (let at = 0; at < noise.data.length; at += 4) {
            const value = (Math.random() * 255) | 0;
            noise.data[at] = noise.data[at + 1] = noise.data[at + 2] = value;
            noise.data[at + 3] = 255;
          }
          context.putImageData(noise, 0, 0);
          out.push(canvas.toDataURL("image/jpeg", 0.8).slice("data:image/jpeg;base64,".length));
        }
        state.jpegs ??= new Map();
        state.jpegs.set(key, out);
        return out;
      };
      (window as unknown as { makeFrames(): void }).makeFrames = () => {
        for (const v of videos) {
          jpegs(v, 320, 1);
          jpegs(v, 1024, 4);
          jpegs(v, 1280, 16);
        }
      };
      const probes = (v: Video) => {
        const count = Math.min(48, Math.max(12, v.seconds * 2));
        return Array.from({ length: count }, (_, index) => {
          const cells = new Uint8Array(24 * 24);
          // A scene change every few seconds, so the page picks frames at each.
          cells.fill(Math.floor(index / 6) * 40);
          return {
            atMs: Math.round(((index + 0.5) * v.seconds * 1000) / count),
            cells: btoa(String.fromCharCode(...cells)),
          };
        });
      };
      const answer = (method: string, params: Record<string, unknown>): Promise<unknown> | undefined => {
        const v = video(params.src);
        switch (method) {
          case "chat.attach.dropped": {
            const names = (params.names as string[]) ?? [];
            return after(5, {
              items: names.map((name) => ({
                path: `/Users/leo/Desktop/${name}`,
                folder: false,
              })),
            });
          }
          case "video.info": {
            if (!v) return undefined;
            const frames = jpegs(v, 1024, 4);
            return after(350, {
              durationMs: v.seconds * 1000,
              width: v.width,
              height: v.height,
              poster: "data:image/jpeg;base64," + jpegs(v, 320, 1)[0],
              frames: frames.map((data, index) => ({
                atMs: Math.round(((index + 0.5) * v.seconds * 1000) / 4),
                data,
              })),
              probes: probes(v),
            });
          }
          case "video.frames": {
            if (!v) return undefined;
            const frames = jpegs(v, 1280, 16);
            const times = (params.times as number[]) ?? [];
            return after(900, {
              frames: times.map((atMs, index) => ({
                atMs,
                data: frames[index % frames.length],
              })),
            });
          }
          case "video.transcript":
            return after(2500, {
              segments: [
                {
                  startMs: 0,
                  endMs: 4000,
                  text: "this is the bug I keep seeing in the composer",
                },
              ],
              heardMs: (v?.seconds ?? 1) * 1000,
              durationMs: (v?.seconds ?? 1) * 1000,
              engine: "speechAnalyzer",
              locale: "en-US",
            });
          default:
            return undefined;
        }
      };
      const reply = (method: string, params: Record<string, unknown>) => {
        ((window as unknown as { all: string[] }).all ??= []).push(method);
        const value = answer(method, params);
        if (!value) return Promise.resolve({ ok: true, value: null });
        state.pending += 1;
        return value.then((value) => {
          state.pending -= 1;
          state.calls.push({
            method,
            at: performance.now(),
            bytes: JSON.stringify(value).length,
          });
          return { ok: true, value };
        });
      };
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: {
              postMessage: (message: { method: string; params: Record<string, unknown> }) =>
                reply(message.method, message.params),
            },
          },
        },
        // The worked mock chat: its folder is on this Mac, so a paste goes as its path.
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock" }),
        },
      });
    }, videos);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.evaluate(() => (window as unknown as { makeFrames(): void }).makeFrames());
    return page;
  }

  /// Starts the heartbeat and the long-task record.
  const startTiming = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as {
        stall: number;
        beat: number;
        long: number;
        longCount: number;
        observer: PerformanceObserver;
      };
      state.stall = 0;
      state.long = 0;
      state.longCount = 0;
      let last = performance.now();
      state.beat = window.setInterval(() => {
        const now = performance.now();
        state.stall = Math.max(state.stall, now - last);
        last = now;
      }, 4);
      state.observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          state.long += entry.duration;
          state.longCount += 1;
        }
      });
      try {
        state.observer.observe({ type: "longtask" });
      } catch {}
    });

  const stopTiming = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as {
        stall: number;
        beat: number;
        long: number;
        longCount: number;
        observer: PerformanceObserver;
      };
      window.clearInterval(state.beat);
      state.observer.disconnect();
      return {
        stall: state.stall,
        long: state.long,
        longCount: state.longCount,
      };
    });

  /// Pastes recording `index` into the prompt as ⌘V of a file copied in Finder does: a File the
  /// host knows the path of.
  const pasteVideo = (page: Page, videos: Video[], index: number) =>
    page.evaluate(
      ({ index, videos }) => {
        const v = videos[index]!;
        // A few MB of movie: the page reads only its header (videoShape.ts).
        const file = new File([new Uint8Array(3 * 1024 * 1024)], v.name, {
          type: "video/quicktime",
        });
        const data = new DataTransfer();
        data.items.add(file);
        const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
        target.dispatchEvent(
          new ClipboardEvent("paste", {
            clipboardData: data,
            bubbles: true,
            cancelable: true,
          }),
        );
      },
      { index, videos },
    );

  /// Every read answered and its answer landed (the transcript is the last to come).
  const allRead = (page: Page) =>
    page.waitForFunction(
      () => {
        const state = window as unknown as {
          calls: { method: string }[];
          pending: number;
        };
        return state.pending === 0 && state.calls.filter((call) => call.method === "video.transcript").length === 2;
      },
      undefined,
      { timeout: 30_000 },
    );

  for (const [engine] of engines)
    for (const [label, videos] of SETS)
      test(`${engine}: ${label} pasted back to back never freeze the composer`, async () => {
        const page = await newChat(engine, videos);
        const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
        await prompt.click();
        // The page's own stalls while typing with nothing attached.
        await startTiming(page);
        await page.keyboard.type(" idle", { delay: 20 });
        const idle = await stopTiming(page);
        for (let at = 0; at < 5; at += 1) await page.keyboard.press("Backspace");

        await startTiming(page);
        const started = Date.now();
        await pasteVideo(page, videos, 0);
        // "one after the other really quickly"
        // fixed-wait: the gap between the two pastes is the behavior measured.
        await page.waitForTimeout(150);
        await pasteVideo(page, videos, 1);
        await page.keyboard.type(" both of these recordings", { delay: 20 });
        await allRead(page).catch(async (error) => {
          const seen = await page.evaluate(() => ({
            calls: (window as unknown as { calls: { method: string }[] }).calls.map((call) => call.method),
            all: (window as unknown as { all: string[] }).all,
            html: document.querySelector(".acpmux-composer")?.outerHTML.slice(0, 3000),
          }));
          console.log(JSON.stringify(seen, null, 1));
          throw error;
        });
        // Let the last answer's render land.
        // fixed-wait: a render after the last answer has no event of its own; the heartbeat must cover it.
        await page.waitForTimeout(300);
        const timed = await stopTiming(page);
        const calls = await page.evaluate(
          () =>
            (
              window as unknown as {
                calls: { method: string; bytes: number }[];
              }
            ).calls,
        );
        const bytes = (method: string) =>
          calls.filter((call) => call.method === method).reduce((sum, call) => sum + call.bytes, 0);
        console.log(
          `${engine}, ${label}: read in ${Date.now() - started} ms; video.info ${(bytes("video.info") / 1024).toFixed(0)} KB, video.frames ${(bytes("video.frames") / 1024).toFixed(0)} KB; longest main-thread stall ${timed.stall.toFixed(0)} ms (idle ${idle.stall.toFixed(0)} ms), long tasks ${timed.longCount} totalling ${timed.long.toFixed(0)} ms (idle ${idle.long.toFixed(0)} ms)`,
        );
        expect(await page.locator(".acpmux-attachment-video").count()).toBe(2);
        expect(timed.stall).toBeLessThan(Math.max(MAX_STALL_MS, idle.stall + 50));
        await page.close();
      });
});
