// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-10-29: "Also, when I'm looking at fucking images, I don't want the screen to flicker.
// The screen fucking flickers." Looking at a chat's images, in the transcript and in the image
// viewer over it, never blinks: while a turn streams behind, an image already shown keeps its
// element, its src and full opacity on every painted frame; the viewer fades in once when it
<<<<<<< Updated upstream
// opens and out once when it closes, and nothing under it fades again; while it is open, the turn
// streaming behind it never shows through it (a still image is still pixels, frame after frame).
=======
// opens and out once when it closes, and nothing under it fades again.
>>>>>>> Stashed changes
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon that streams the reply. A per-frame sampler (support/paintedFrames) records what each
// painted frame shows. The app draws the pane in WebKit, so each case runs in Chromium and WebKit.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { deflateSync } from "node:zlib";
<<<<<<< Updated upstream
import { PNG } from "pngjs";
=======
>>>>>>> Stashed changes
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// A real, decodable PNG data URL (a screenshot-sized gradient with bands), so the engine decodes
/// it as it would a pasted screenshot.
function png(width: number, height: number, hue: number): string {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (bytes: Uint8Array) => {
    let c = 0xffffffff;
    for (const byte of bytes) c = crcTable[(c ^ byte) & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Uint8Array) => {
    const out = new Uint8Array(12 + data.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, data.length);
    out.set(new TextEncoder().encode(type), 4);
    out.set(data, 8);
    view.setUint32(8 + data.length, crc(out.subarray(4, 8 + data.length)));
    return out;
  };
  const header = new Uint8Array(13);
  const headerView = new DataView(header.buffer);
  headerView.setUint32(0, width);
  headerView.setUint32(4, height);
  header.set([8, 2, 0, 0, 0], 8);
  const raw = new Uint8Array((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 3 + 1);
    for (let x = 0; x < width; x++) {
      const band = Math.floor(y / 40) % 2 ? 40 : 0;
      raw[row + 1 + x * 3] = (hue + (x * 255) / width) & 0xff;
      raw[row + 2 + x * 3] = ((y * 255) / height + band) & 0xff;
      raw[row + 3 + x * 3] = (255 - (x * 255) / width) & 0xff;
    }
  }
  const signature = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const parts = [signature, chunk("IHDR", header), chunk("IDAT", deflateSync(raw)), chunk("IEND", new Uint8Array())];
  const bytes = Buffer.concat(parts);
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

await requireBrowserLane("image-viewer-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`image-viewer-frames: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("image viewer frames", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d7";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Screenshots",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: Date.now(),
  };
  const update = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  const FIRST = png(960, 600, 0);
  const SECOND = png(960, 600, 120);
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  // Earlier turns, so the transcript virtualizes: a row scrolled far enough away unmounts.
  for (let turn = 1; turn <= 24; turn++) {
    record("mux", "user_message", { text: `Question ${turn}`, promptId: `h-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      update(Array.from({ length: 6 }, (_, index) => `Earlier answer ${turn}, paragraph ${index + 1}. `.repeat(6)).join("\n\n")),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  record("mux", "user_message", { text: "Show me the build chart", promptId: "p-0" });
  record("mux", "turn_started", {});
  record("in", "agent_message_chunk", update(`Here is the build chart.\n\n![Build chart](${FIRST})\n\nThat is all.`));
  record("mux", "turn_result", { status: "completed" });
  const opened = events.length;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  /// The page the reply streams to: a chunk goes out every two frames it paints, until `release`.
  let streamingTo: Page | undefined;
  let hold: Promise<void> = Promise.resolve();
  let release = () => {};
  /// acpmux's run of a prompt: the reply streams a sentence at a time, with an image of its own
  /// partway, then waits for the test to release its end.
  async function run(ws: { send(data: string): void }, params: Record<string, any>, id: number, chunks: number) {
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    send(record("mux", "user_message", { text, promptId: params._meta?.acpmux?.promptId }));
    send(record("mux", "turn_started", {}));
    for (let index = 1; index <= chunks; index++) {
      const sentence =
        index === Math.floor(chunks / 3)
          ? `\n\n![Retry chart](${SECOND})\n\n`
          : `Sentence ${index} of the reply streams in behind the image. `;
      send(record("in", "agent_message_chunk", update(sentence)));
      for (let frame = 0; frame < 2; frame++) await streamingTo?.evaluate(() => window.cmuxPaintFrame());
    }
    await hold;
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  let chunks = 90;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt" && message.id !== undefined) {
            void run(ws, message.params ?? {}, message.id, chunks);
            return;
          }
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Shown = { id: number; key: string; opacity: number; ready: boolean };
  type Frame = {
    at: number;
    /// The viewer's dialog and backdrop opacity, absent when it is closed.
    dialog?: number;
    backdrop?: number;
    /// The viewer's image.
    viewer?: Shown;
    /// The transcript's images.
    transcript: Shown[];
  };

  /// Starts sampling every painted frame into `window.imageFrames` until `window.imageFramesStop()`.
  const sample = (page: Page) =>
    page.evaluate(() => {
      const ids = new WeakMap<Element, number>();
      let next = 1;
      const id = (element: Element) => {
        if (!ids.has(element)) ids.set(element, next++);
        return ids.get(element)!;
      };
      // A data URL's length and tail name it without holding it.
      const key = (image: HTMLImageElement) => `${image.src.length}:${image.src.slice(-24)}`;
      /// The opacity a frame paints an element at: its own times every ancestor's.
      const opacity = (element: Element) => {
        let value = 1;
        for (let at: Element | null = element; at; at = at.parentElement)
          value *= Number(getComputedStyle(at).opacity);
        return Math.round(value * 1000) / 1000;
      };
      const shown = (image: HTMLImageElement) => ({
        id: id(image),
        key: key(image),
        opacity: opacity(image),
        ready: image.complete && image.naturalWidth > 0,
      });
      const frames: unknown[] = [];
      const state = window as unknown as { imageFrames: unknown[]; imageFramesStop: () => void };
      state.imageFrames = frames;
      const start = performance.now();
      state.imageFramesStop = window.cmuxAfterPaint(() => {
        const dialog = document.querySelector(".acpmux-image-viewer");
        const backdrop = document.querySelector(".acpmux-image-viewer-backdrop");
        const viewer = dialog?.querySelector<HTMLImageElement>(".acpmux-image-viewer-image");
        frames.push({
          at: Math.round(performance.now() - start),
          ...(dialog && { dialog: opacity(dialog) }),
          ...(backdrop && { backdrop: opacity(backdrop) }),
          ...(viewer && { viewer: shown(viewer) }),
          transcript: [...document.querySelectorAll<HTMLImageElement>(".acpmux-scroll img.cv-thumb__img")].map(shown),
        });
      });
    });
  const frames = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { imageFrames: Frame[]; imageFramesStop: () => void };
      state.imageFramesStop();
      return state.imageFrames;
    });

  /// Every way the frames blink: an image shown whole that later paints faded, undecoded, or as
  /// another element; the viewer's fade going back on itself.
  function blinks(list: Frame[]): string[] {
    const found: string[] = [];
    const whole = new Map<string, Shown>();
    const check = (where: string, frame: Frame, image: Shown) => {
      const before = whole.get(`${where}:${image.key}`);
      if (before && (image.opacity < 1 || !image.ready || (where === "viewer" && image.id !== before.id)))
        found.push(
          `${frame.at} ms: the ${where} image ${image.key.slice(0, 12)} ` +
            (image.opacity >= 1 && image.ready
              ? `became a new element (${before.id} -> ${image.id})`
              : !image.ready
                ? "painted undecoded"
                : `painted at opacity ${image.opacity}`),
        );
      if (image.opacity >= 1 && image.ready) whole.set(`${where}:${image.key}`, image);
    };
    let dialogBefore: number | undefined;
    let dialogPeak = 0;
    let wasOpen = false;
    for (const frame of list) {
      for (const image of frame.transcript) check("transcript", frame, image);
      if (frame.viewer) check("viewer", frame, frame.viewer);
      // The viewer fades in to 1 and out to 0, each once: a fade back up or down mid-way blinks.
      if (frame.dialog !== undefined) {
        if (dialogBefore !== undefined && frame.dialog < dialogBefore && dialogPeak < 1)
          found.push(`${frame.at} ms: the viewer faded back from ${dialogBefore} to ${frame.dialog} while opening`);
        if (dialogPeak >= 1 && dialogBefore !== undefined && frame.dialog > dialogBefore)
          found.push(`${frame.at} ms: the viewer faded back up from ${dialogBefore} to ${frame.dialog}`);
        if (frame.viewer && frame.dialog > 0 && !frame.viewer.ready)
          found.push(`${frame.at} ms: the viewer showed without its image decoded`);
        dialogPeak = Math.max(dialogPeak, frame.dialog);
        dialogBefore = frame.dialog;
        wasOpen = true;
      } else if (wasOpen) {
        dialogBefore = undefined;
        dialogPeak = 0;
        wasOpen = false;
        // A closed viewer forgets its image: the next open is a new element.
        for (const key of [...whole.keys()]) if (key.startsWith("viewer:")) whole.delete(key);
      }
    }
    return found;
  }

  async function openChat(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 680 } });
    await installPaintedFrames(page);
    streamingTo = page;
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("That is all.").waitFor();
    await page.waitForFunction(() => {
      const image = document.querySelector<HTMLImageElement>(".acpmux-scroll img.cv-thumb__img");
      return image?.complete && image.naturalWidth > 0;
    });
    // The first image's own fade-in is done before sampling starts.
    for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    return page;
  }
  async function send(page: Page, prompt: string) {
    hold = new Promise((done) => (release = done));
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(prompt);
    await page.keyboard.press("Enter");
    await page.getByText("Sentence 2 of the reply", { exact: false }).waitFor({ state: "attached" });
  }
  async function finish(page: Page) {
    await page.getByText(`Sentence ${chunks} of the reply`, { exact: false }).waitFor({ state: "attached" });
    release();
    await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached" });
    for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  }
  const report = (name: string, label: string, list: Frame[], found: string[]) =>
    console.log(
      `image-viewer-frames ${name} ${label}: ${list.length} frames, ${found.length} blinks` +
        (found.length ? `\n  ${found.slice(0, 12).join("\n  ")}` : ""),
    );

  test.each(engines.map(([name]) => name))(
    "%s: images in the transcript never blink while a turn streams and ends",
    async (name) => {
      const page = await openChat(name);
      await sample(page);
      await send(page, "Stream a reply with a chart");
      await finish(page);
      const list = await frames(page);
      const found = blinks(list);
      report(name, "transcript", list, found);
      await page.close();
      expect(list.some((frame) => frame.transcript.length === 2)).toBe(true);
      expect(found).toEqual([]);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: the image viewer opens, holds and closes without a blink while a turn streams behind",
    async (name) => {
      const page = await openChat(name);
      await sample(page);
      await send(page, "Stream a reply while I look");
      await page.getByRole("button", { name: "Build chart" }).first().click();
      await page.getByRole("dialog", { name: "Build chart" }).waitFor();
      // The turn streams behind the open viewer, its own image included.
      await page.getByText(`Sentence ${chunks - 10} of the reply`, { exact: false }).waitFor({ state: "attached" });
      await page.keyboard.press("Escape");
      await page.getByRole("dialog").waitFor({ state: "detached" });
      await finish(page);
      const list = await frames(page);
      const found = blinks(list);
      report(name, "viewer", list, found);
      await page.close();
      expect(list.some((frame) => frame.viewer?.ready && frame.dialog === 1)).toBe(true);
      expect(found).toEqual([]);
    },
  );
<<<<<<< Updated upstream

  test.each(engines.map(([name]) => name))(
    "%s: an image scrolled away and back paints whole, never faded or blank, while a turn streams",
    async (name) => {
      const page = await openChat(name);
      await send(page, "Stream while I scroll");
      await sample(page);
      // Up past the image until its row unmounts, then back down to it, twice.
      for (let pass = 0; pass < 2; pass++) {
        await page.evaluate(() => {
          document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
        });
        await page.waitForFunction(() => !document.querySelector(".acpmux-scroll img.cv-thumb__img"));
        for (let frame = 0; frame < 4; frame++) await page.evaluate(() => window.cmuxPaintFrame());
        // Back to the latest turn, then up to the image as its row mounts again.
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = scroller.scrollHeight;
        });
        await page.waitForFunction(() => document.querySelector(".acpmux-scroll img.cv-thumb__img"));
        await page.evaluate(() =>
          document.querySelector(".acpmux-scroll img.cv-thumb__img")!.scrollIntoView({ block: "center" }),
        );
        for (let frame = 0; frame < 20; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      }
      await finish(page);
      const list = await frames(page);
      const found = blinks(list);
      report(name, "remount", list, found);
      await page.close();
      expect(list.some((frame) => frame.transcript.length > 0)).toBe(true);
      expect(found).toEqual([]);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: the open image viewer's pixels hold still while a turn streams behind it",
    async (name) => {
      // A longer reply, so it streams through every shot.
      chunks = 160;
      const page = await openChat(name);
      await send(page, "Stream a reply while I stare");
      await page.getByRole("button", { name: "Build chart" }).first().click();
      const dialog = page.getByRole("dialog", { name: "Build chart" });
      await dialog.waitFor();
      // The dialog's fade-in is over before the pixels are compared.
      await page.waitForFunction(() => {
        const element = document.querySelector(".acpmux-image-viewer");
        return element && Number(getComputedStyle(element).opacity) === 1;
      });
      for (let frame = 0; frame < 10; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      const box = (await dialog.boundingBox())!;
      const shots: PNG[] = [];
      for (let shot = 0; shot < 16; shot++) {
        shots.push(PNG.sync.read(await page.screenshot({ clip: box, animations: "allow" })));
        for (let frame = 0; frame < 3; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      }
      const streamed = await page.evaluate(() => document.body.innerText.match(/Sentence (\d+) of the reply/g)?.length ?? 0);
      await page.keyboard.press("Escape");
      await finish(page);
      await page.close();
      chunks = 90;
      // Pixels of the viewer that changed from one shot to the next (any channel by more than 2).
      const changed = shots.slice(1).map((after, index) => {
        const before = shots[index]!;
        let count = 0;
        for (let at = 0; at < after.data.length; at += 4)
          if (
            Math.abs(after.data[at]! - before.data[at]!) > 2 ||
            Math.abs(after.data[at + 1]! - before.data[at + 1]!) > 2 ||
            Math.abs(after.data[at + 2]! - before.data[at + 2]!) > 2
          )
            count++;
        return count;
      });
      console.log(
        `image-viewer-frames ${name} viewer pixels: ${Math.round(box.width)}x${Math.round(box.height)}, ` +
          `${streamed} sentences streamed behind, changed pixels per shot: ${changed.join(" ")}`,
      );
      expect(streamed).toBeGreaterThan(0);
      expect(Math.max(...changed)).toBe(0);
    },
  );
=======
>>>>>>> Stashed changes
});
