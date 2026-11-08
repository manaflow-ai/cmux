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
// The page is the pane's dev entry with the in-page mock transport.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Rect = { x: number; y: number; width: number; height: number };
type Frame = { tile?: Rect; where?: string; box: number; row?: Rect };
type Way = "paste" | "drop" | "pick";
type ProbeWindow = Window & {
  __probe?: { frames: Frame[]; stop: boolean; before: Set<Element> };
  __images?: Record<string, File>;
};

await requireBrowserLane("composer-attach-no-jump.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-attach-no-jump: skipping (run `bunx playwright install chromium`)");
    describe.skip("attachment slots", () => test("chromium", () => {}));
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

  const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

  async function newChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
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
        const fresh = tiles().filter((tile) => !probe.before.has(tile) && tile.getBoundingClientRect().width > 0);
        const old = [...probe.before].find((tile) => tile.isConnected);
        const tile = fresh[0];
        probe.frames.push({
          box: box.getBoundingClientRect().height,
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
          field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
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
        for (const type of ["dragenter", "dragover", "drop"]) target.dispatchEvent(new DragEvent(type, init));
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
  async function trace(way: Way, width: number, height: number): Promise<Frame[]> {
    const page = await newChat();
    await makeImage(page, "first.png", 2880, 900);
    await makeImage(page, "second.png", width, height);
    await gesture(page, "paste", "first.png");
    await settled(page, 1);
    await page.locator(PROMPT).click();
    await page.keyboard.press("End");
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
    // The composer never grows past where it ends.
    const finalBox = frames.at(-1)!.box;
    for (const frame of frames) expect(frame.box).toBeLessThanOrEqual(finalBox + 1);
  }

  test("a wide image pasted beside an attachment takes its final slot from its first frame", async () => {
    check("paste wide", await trace("paste", 2880, 900));
  });

  test("a tall image pasted beside an attachment takes its final slot from its first frame", async () => {
    check("paste tall", await trace("paste", 900, 2880));
  });

  test("a wide image dropped beside an attachment takes its final slot from its first frame", async () => {
    check("drop wide", await trace("drop", 2880, 900));
  });

  test("a wide image picked in the + menu takes its final slot from its first frame", async () => {
    check("pick wide", await trace("pick", 2880, 900));
  });
});
