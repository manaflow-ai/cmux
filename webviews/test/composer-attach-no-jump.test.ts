// Leo, 2026-11-07: "when it's like oblong or rectangular type attachments, they go up top above and
// then they land to where they should be. And so, like, for example, this case, there was a weird,
// like, okay, I paste it and it pasted above the original picture, which would, like, extend the
// composer, even though there's, you know, why would you extend upwards if you still have space,
// right? So. I think it's like the calculation of the paste preview, perhaps like accounted for the
// picture size itself rather than what the preview size would be."
//
// A new attachment takes its final slot from its first frame: a wide (or tall) image's loading tile
// is the size and place its thumbnail ends at, the composer grows only if the row needs another line,
// and nothing moves when the picture arrives. Each way in is covered: a paste, a drop, a file pick.
//
// Each frame also checks every tile, not only the new one: no attachment is ever drawn in the strip
// above the text (the inline view puts them all in the text), and the one already there never moves.
//
// The page is the pane's dev entry with the in-page mock transport. Both engines: the app's WebKit
// and Chromium; CI fails the file when one cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { x: number; y: number; width: number; height: number };
type Tile = { rect: Rect; where: string; fresh: boolean };
type Frame = { tile?: Rect; where?: string; box: number; top: number; row?: Rect; tiles: Tile[] };
type Way = "paste" | "drop" | "pick";
type ProbeWindow = Window & {
  __probe?: { frames: Frame[]; stop: boolean; before: Set<Element> };
  __images?: Record<string, File>;
};

await requireBrowserLane("composer-attach-no-jump.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-attach-no-jump: ${name} did not launch`);
      console.warn(`composer-attach-no-jump: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("attachment slots", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
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
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

  async function newChat(engine: string, width = 900): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 640 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: { postMessage: async () => ({ ok: true, value: null }) },
          },
        },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }),
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.locator(PROMPT).click();
    return page;
  }

  /// Makes a screenshot-like PNG of `width` x `height` in the page, kept as `window.__images[name]`.
  const makeImage = (page: Page, name: string, width: number, height: number) =>
    page.evaluate(
      async ({ name, width, height }) => {
        const canvas = document.createElement("canvas");
        canvas.width = width;
        canvas.height = height;
        const context = canvas.getContext("2d")!;
        context.fillStyle = "#1b1c20";
        context.fillRect(0, 0, width, height);
        context.fillStyle = "#d6d7db";
        context.font = "28px sans-serif";
        for (let line = 0; line * 32 < height; line += 1)
          context.fillText(`line ${line} ${"x".repeat(line % 50)}`, 24, 32 + line * 32);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        const state = window as ProbeWindow;
        state.__images = { ...state.__images, [name]: new File([blob], name, { type: "image/png" }) };
      },
      { name, width, height },
    );

  /// Starts sampling every frame: the new attachment's tile (an element not in the composer before),
  /// the composer's height, and the row the existing attachments sit in.
  const startProbe = (page: Page) =>
    page.evaluate(() => {
      const box = document.querySelector(".acpmux-composer-box")!;
      const tiles = () => [...box.querySelectorAll(".acpmux-md-inline-chip, .acpmux-attachments .acpmux-attachment")];
      const probe = { frames: [] as Frame[], stop: false, before: new Set(tiles()) };
      (window as ProbeWindow).__probe = probe;
      const rect = (element: Element): Rect => {
        const { x, y, width, height } = element.getBoundingClientRect();
        return { x, y, width, height };
      };
      const sample = () => {
        if (probe.stop) return;
        const all = tiles().filter((tile) => tile.getBoundingClientRect().width > 0);
        const fresh = all.filter((tile) => !probe.before.has(tile));
        const old = [...probe.before].find((tile) => tile.isConnected);
        const tile = fresh[0];
        probe.frames.push({
          box: box.getBoundingClientRect().height,
          top: box.getBoundingClientRect().top,
          tiles: all.map((each) => ({
            rect: rect(each),
            where: each.closest(".acpmux-attachments") ? "strip" : "text",
            fresh: !probe.before.has(each),
          })),
          ...(tile
            ? {
                tile: rect(tile),
                where: tile.closest(".acpmux-attachments") ? "strip" : (tile.getAttribute("data-state") ?? "?"),
              }
            : {}),
          ...(old ? { row: rect(old) } : {}),
        });
        // raf-read: the measurement is every frame from the gesture until it settles.
        requestAnimationFrame(sample);
      };
      // raf-read: the same sampling, from the gesture's frame.
      requestAnimationFrame(sample);
    });

  /// Pastes or drops image `name` (the pick goes through the + menu's file chooser instead).
  const gesture = (page: Page, way: Way, name: string) =>
    page.evaluate(
      ({ way, name, prompt }) => {
        const data = new DataTransfer();
        data.items.add((window as ProbeWindow).__images![name]!);
        const field = document.querySelector(prompt)!;
        if (way === "paste") {
          const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
          // WebKit's constructor drops the clipboard; the app's paste route hands it on the same way.
          if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
          field.dispatchEvent(paste);
          return;
        }
        const target = document.querySelector(".acpmux-composer-box")!;
        const box = target.getBoundingClientRect();
        const init = {
          dataTransfer: data,
          bubbles: true,
          cancelable: true,
          clientX: box.left + Math.min(40, box.width / 2),
          clientY: box.top + box.height / 2,
        };
        for (const type of ["dragenter", "dragover", "drop"]) {
          const drag = new DragEvent(type, init);
          if (drag.dataTransfer !== data) Object.defineProperty(drag, "dataTransfer", { value: data });
          target.dispatchEvent(drag);
        }
      },
      { way, name, prompt: PROMPT },
    );

  async function pick(page: Page, name: string) {
    const bytes = await page.evaluate(async (name) => {
      const file = (window as ProbeWindow).__images![name]!;
      const data = new Uint8Array(await file.arrayBuffer());
      let text = "";
      for (const byte of data) text += String.fromCharCode(byte);
      return btoa(text);
    }, name);
    await page.locator(".acpmux-composer-plus .acpmux-picker-button").click();
    const chooser = page.waitForEvent("filechooser", { timeout: 5_000 });
    await page.locator('[role="menu"] [role="menuitem"][data-value="add.files"]').click();
    await (await chooser).setFiles({ name, mimeType: "image/png", buffer: Buffer.from(bytes, "base64") });
  }

  /// Every attachment in the composer drawn as its ready picture, nothing loading.
  const settled = (page: Page, count: number) =>
    page.waitForFunction(
      (count) => {
        const box = document.querySelector(".acpmux-composer-box")!;
        if (box.querySelector('[aria-busy="true"]')) return false;
        const images = [...box.querySelectorAll<HTMLImageElement>(".acpmux-attachment-image img")];
        return images.length === count && images.every((img) => img.complete && img.naturalWidth > 0);
      },
      count,
      { polling: 20, timeout: 30_000 },
    );

  /// Attaches `name` by `way` into a composer that already holds one attachment, and answers every
  /// frame sampled from the gesture until it settled (plus a few frames after).
  /// `again`: the second paste follows the first with nothing between, the caret where the first left it.
  async function trace(
    engine: string,
    way: Way,
    width: number,
    height: number,
    again = false,
    pane = 900,
    room?: number,
  ): Promise<Frame[]> {
    const page = await newChat(engine, pane);
    if (pane < 900) await page.keyboard.type("Compare these two screenshots of the settings page ");
    await makeImage(page, "first.png", 2880, 900);
    await makeImage(page, "second.png", width, height);
    await gesture(page, "paste", "first.png");
    await settled(page, 1);
    if (!again) {
      await page.locator(PROMPT).click();
      await page.keyboard.press("End");
    }
    // `room`: the line after the attachment keeps only this much width, so a tile wider than the
    // new one's final size would wrap to a line of its own.
    if (room !== undefined)
      await page.evaluate(
        ({ prompt, room }) => {
          const field = document.querySelector<HTMLElement>(prompt)!;
          const chip = field.querySelector(".acpmux-md-inline-chip")!;
          const gap = parseFloat(getComputedStyle(chip).marginInlineEnd) || 0;
          const end = chip.getBoundingClientRect().right + gap;
          const style = getComputedStyle(field);
          const inset = parseFloat(style.paddingRight) + parseFloat(style.borderRightWidth);
          field.style.width = `${end + room + inset - field.getBoundingClientRect().left}px`;
          field.style.flex = "none";
        },
        { prompt: PROMPT, room },
      );
    await startProbe(page);
    if (way === "pick") await pick(page, "second.png");
    else await gesture(page, way, "second.png");
    await settled(page, 2);
    // A few more frames, so the last sample is the settled layout.
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let left = 10;
          // raf-read: waits out ten frames after the settle.
          const tick = () => (--left <= 0 ? resolve() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
    );
    const frames = await page.evaluate(() => {
      const probe = (window as ProbeWindow).__probe!;
      probe.stop = true;
      return probe.frames;
    });
    await page.close();
    return frames;
  }

  const close = (a: Rect, b: Rect) =>
    Math.abs(a.x - b.x) <= 1 &&
    Math.abs(a.y - b.y) <= 1 &&
    Math.abs(a.width - b.width) <= 1 &&
    Math.abs(a.height - b.height) <= 1;

  function check(label: string, frames: Frame[]) {
    const shown = frames.filter((frame) => frame.tile);
    const summary = shown
      .map(
        (frame) =>
          `${frame.where}@${Math.round(frame.tile!.x)},${Math.round(frame.tile!.y)} ${Math.round(frame.tile!.width)}x${Math.round(frame.tile!.height)} box=${Math.round(frame.box)}`,
      )
      .filter((line, index, all) => index === 0 || line !== all[index - 1]);
    console.log(`composer-attach-no-jump ${label}: ${summary.join(" | ")}`);
    const every = frames
      .map((frame) =>
        frame.tiles
          .map(
            (each) =>
              `${each.fresh ? "new" : "old"}:${each.where}@${Math.round(each.rect.x)},${Math.round(each.rect.y)} ${Math.round(each.rect.width)}x${Math.round(each.rect.height)}`,
          )
          .join(" "),
      )
      .filter((line, index, all) => index === 0 || line !== all[index - 1]);
    console.log(`composer-attach-no-jump ${label} tiles: ${every.join(" | ")}`);
    expect(shown.length).toBeGreaterThan(0);
    const first = shown[0]!;
    const last = shown.at(-1)!;
    // Its first frame is its last: the same place and size.
    expect(close(first.tile!, last.tile!)).toBe(true);
    for (const frame of shown) {
      // Never somewhere else in between.
      expect(close(frame.tile!, last.tile!)).toBe(true);
      // Never above the row the attachments sit in.
      if (frame.row) expect(frame.tile!.y).toBeGreaterThanOrEqual(frame.row.y - 1);
    }
    // Every tile, in every frame, is in the text (the inline view draws no strip), and the one
    // already there keeps its place in the composer (which grows upward from its bottom edge, so
    // its place is read from the composer's top) and its size.
    const final = frames.at(-1)!;
    for (const frame of frames) {
      expect(frame.tiles.filter((each) => each.where === "strip")).toEqual([]);
      if (frame.row && final.row)
        expect(close({ ...frame.row, y: frame.row.y - frame.top }, { ...final.row, y: final.row.y - final.top })).toBe(
          true,
        );
    }
    // The composer never grows past where it ends.
    const finalBox = frames.at(-1)!.box;
    for (const frame of frames) expect(frame.box).toBeLessThanOrEqual(finalBox + 1);
  }

  for (const [engine] of engines) {
    test(`${engine}: a wide image pasted beside an attachment takes its final slot from its first frame`, async () => {
      check(`${engine} paste wide`, await trace(engine, "paste", 2880, 900));
    });

    test(`${engine}: a wide image pasted right after another goes after it, from its first frame`, async () => {
      const frames = await trace(engine, "paste", 2880, 900, true);
      check(`${engine} paste again`, frames);
      const last = frames.at(-1)!.tiles;
      const fresh = last.find((each) => each.fresh)!;
      const old = last.find((each) => !each.fresh)!;
      // After the first in reading order: right of it on its line, or on a line below.
      expect(fresh.rect.y > old.rect.y + 1 || fresh.rect.x > old.rect.x).toBe(true);
    });

    test(`${engine}: in a narrow pane, a wide image pasted after text and an attachment takes its final slot`, async () => {
      check(`${engine} paste narrow`, await trace(engine, "paste", 2880, 900, true, 420));
    });

    test(`${engine}: a tall image pasted where only its own width fits stays on the line, from its first frame`, async () => {
      const frames = await trace(engine, "paste", 900, 2880, false, 900, 60);
      check(`${engine} paste tall in tight room`, frames);
      const last = frames.at(-1)!.tiles;
      const fresh = last.find((each) => each.fresh)!;
      const old = last.find((each) => !each.fresh)!;
      // Beside the attachment, on its line: the 48 px tile fit in the 60 px left.
      expect(Math.abs(fresh.rect.y - old.rect.y)).toBeLessThanOrEqual(1);
    });

    test(`${engine}: a tall image pasted beside an attachment takes its final slot from its first frame`, async () => {
      check(`${engine} paste tall`, await trace(engine, "paste", 900, 2880));
    });

    test(`${engine}: a wide image dropped beside an attachment takes its final slot from its first frame`, async () => {
      check(`${engine} drop wide`, await trace(engine, "drop", 2880, 900));
    });

    test(`${engine}: a wide image picked in the + menu takes its final slot from its first frame`, async () => {
      check(`${engine} pick wide`, await trace(engine, "pick", 2880, 900));
    });
  }
});
