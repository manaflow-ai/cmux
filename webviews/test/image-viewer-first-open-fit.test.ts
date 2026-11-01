// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The image viewer fits the image to the pane on every open, the first one too (#27955: the first
// open of a chat image showed it far zoomed in, cropped by the stage; a second open fitted it).
// A double click on the thumbnail opened the viewer on its first click, and its second click
// landed on the new stage as a double click, which zooms. ImageViewer.tsx zooms only on a double
// click whose first press was on the stage; a double click there still zooms.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts), with a reply that shows a screenshot-sized PNG. Real Chromium and
// WebKit (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/image-viewer-first-open-fit.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { deflateSync } from "node:zlib";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("image-viewer-first-open-fit.test.ts", async () => {
  /// A `width` x `height` PNG (8-bit RGB, a diagonal ramp) as a data URL: a screenshot's size.
  function png(width: number, height: number): string {
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
    const rows = new Uint8Array((width * 3 + 1) * height);
    for (let y = 0; y < height; y++)
      for (let x = 0; x < width; x++) {
        const at = y * (width * 3 + 1) + 1 + x * 3;
        rows[at] = (x * 255) / width;
        rows[at + 1] = (y * 255) / height;
        rows[at + 2] = 160;
      }
    const parts = [
      new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]),
      chunk("IHDR", header),
      chunk("IDAT", deflateSync(rows)),
      chunk("IEND", new Uint8Array()),
    ];
    return `data:image/png;base64,${Buffer.concat(parts).toString("base64")}`;
  }

  const WIDTH = 2400;
  const HEIGHT = 1600;
  const SHOT = png(WIDTH, HEIGHT);

  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`image-viewer-first-open-fit: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("image viewer first open", () => test("browsers", () => {}));
    return;
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    pane = await papercutPane(() => current!, {
      turns: 1,
      running: false,
      ready: "img.cv-thumb__img",
      extra: [
        ["mux", "user_message", { text: "Take a screenshot" }],
        ["mux", "turn_started", {}],
        [
          "in",
          "agent_message_chunk",
          {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: {
                sessionUpdate: "agent_message_chunk",
                content: { type: "text", text: `Here it is.\n\n![Screenshot](${SHOT})` },
              },
            },
          },
        ],
        ["mux", "turn_result", { status: "completed" }],
      ],
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// Opens the viewer on the reply's image and reads, after every painted frame until the image
  /// has held its box for 10 frames, the image's box against the stage's content box. Returns the
  /// frames where the image (shown, fitted, not zoomed) spilled out of the stage.
  async function openAndRead(page: Page, how: "click" | "dblclick") {
    const thumbnail = page.getByRole("button", { name: "Screenshot" });
    if (how === "dblclick") await thumbnail.dblclick();
    else await thumbnail.click();
    const motion = await page.evaluate(() => {
      const viewer = document.querySelector<HTMLElement>(".acpmux-image-viewer");
      const backdrop = document.querySelector<HTMLElement>(".acpmux-image-viewer-backdrop");
      const image = document.querySelector<HTMLImageElement>(".acpmux-image-viewer-image");
      return {
        viewerTransition: viewer ? getComputedStyle(viewer).transitionDuration : "",
        backdropTransition: backdrop ? getComputedStyle(backdrop).transitionDuration : "",
        imageAnimation: image ? getComputedStyle(image).animationName : "",
      };
    });
    return page.evaluate(async (motion) => {
      const frames: string[] = [];
      const spills: string[] = [];
      let layoutChanges = 0;
      let lastBox = "";
      let last = "";
      let held = 0;
      for (let frame = 0; frame < 600 && held < 10; frame++) {
        await window.cmuxPaintFrame();
        const stage = document.querySelector<HTMLElement>(".acpmux-image-viewer-stage");
        const image = document.querySelector<HTMLImageElement>(".acpmux-image-viewer-image");
        if (!stage || !image) {
          held = 0;
          continue;
        }
        const style = getComputedStyle(stage);
        const box = stage.getBoundingClientRect();
        const left = box.left + parseFloat(style.paddingLeft);
        const right = box.right - parseFloat(style.paddingRight);
        const top = box.top + parseFloat(style.paddingTop);
        const bottom = box.bottom - parseFloat(style.paddingBottom);
        const drawn = image.getBoundingClientRect();
        const boxKey = [drawn.left, drawn.top, drawn.width, drawn.height].map(Math.round).join(",");
        if (lastBox && boxKey !== lastBox) layoutChanges += 1;
        lastBox = boxKey;
        const line =
          `frame ${frame} natural ${image.naturalWidth}x${image.naturalHeight} ` +
          `image ${Math.round(drawn.left)},${Math.round(drawn.top)} ${Math.round(drawn.width)}x${Math.round(drawn.height)} ` +
          `stage ${Math.round(left)},${Math.round(top)} ${Math.round(right - left)}x${Math.round(bottom - top)} ` +
          `zoomed ${stage.classList.contains("is-zoomed")}`;
        frames.push(line);
        const shown = image.naturalWidth > 0 && drawn.width > 0;
        if (
          shown &&
          (drawn.left < left - 1 || drawn.right > right + 1 || drawn.top < top - 1 || drawn.bottom > bottom + 1)
        )
          spills.push(line);
        const now = line.replace(/^frame \d+ /, "");
        held = shown && now === last ? held + 1 : 0;
        last = now;
      }
      return { frames, spills, layoutChanges, motion };
    }, motion);
  }

  for (const [name] of engines)
    describe(name, () => {
      test("a double click on the thumbnail opens the image fitted, as a click does", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        try {
          const first = await openAndRead(page, "dblclick");
          console.log(`${name} first open:\n${first.frames.join("\n")}`);
          expect(first.motion).toEqual({
            viewerTransition: "0s, 0s",
            backdropTransition: "0s",
            imageAnimation: "none",
          });
          expect(first.layoutChanges).toBe(0);
          expect(first.frames.length).toBeGreaterThan(0);
          expect({ open: "first", spills: first.spills, last: first.frames.at(-1) }).toEqual({
            open: "first",
            spills: [],
            last: first.frames.at(-1),
          });
          await page.keyboard.press("Escape");
          await page.locator(".acpmux-image-viewer").waitFor({ state: "detached" });
          const second = await openAndRead(page, "click");
          console.log(`${name} second open:\n${second.frames.join("\n")}`);
          expect({ open: "second", spills: second.spills }).toEqual({ open: "second", spills: [] });
          // Fitted, it is the largest the stage holds at the image's own shape.
          const size = second.frames.at(-1)!.match(/image -?\d+,-?\d+ (\d+)x(\d+) stage -?\d+,-?\d+ (\d+)x(\d+)/)!;
          const [width, height, stageWidth, stageHeight] = size.slice(1).map(Number) as [
            number,
            number,
            number,
            number,
          ];
          const fit = Math.min(stageWidth / WIDTH, stageHeight / HEIGHT);
          expect(Math.abs(width - WIDTH * fit)).toBeLessThanOrEqual(2);
          expect(Math.abs(height - HEIGHT * fit)).toBeLessThanOrEqual(2);
          // A double click on the open image still zooms it.
          await page.locator(".acpmux-image-viewer-image").dblclick();
          await page.locator(".acpmux-image-viewer-stage.is-zoomed").waitFor();
        } finally {
          await page.close();
        }
      });
    });
});
