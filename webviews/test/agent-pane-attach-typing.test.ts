// Leo, 2026-10-13 (cosmic-gray), two bugs in pasting screenshots into the composer:
//
// - Typing on while pasted images attach lost a keystroke, so
// "i cant" + space + "preview" sent "i cantpreview". A paste of only images took the keys for 50 ms
// (ProseMirror's paste capture), and the space typed then came back stripped. The keys typed while
// pasted images attach all land, in order, in the prompt.
// - A dark screenshot's thumbnail was the composer's own dark, so the 2nd and 3rd looked missing, and
//   a 56 px square cropped it to a sliver (Leo, 2026-10-14). A thumbnail keeps the image's shape at a
//   readable size and draws an edge that stands out from both the image and the composer.
// - Leo, 2026-10-18: the strip took ~100 px off the composer (80 px tiles under a 16 px inset, the
//   text 15 px further down). Like the Claude desktop composer it is compact: 64 px tiles 6 px apart
//   in one row, 8 px under the composer's top, the text 6 px under the strip.
// The page is the pane's dev entry with the in-page mock transport.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-attach-typing.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-attach-typing: skipping (run `bunx playwright install chromium`)");
    describe.skip("typing while attaching", () => test("chromium", () => {}));
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

  /// A new chat; `view` "strip" turns on Settings' attachment strip (the default is inline).
  async function newChat(colorScheme: "light" | "dark" = "light", view?: "strip"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 }, colorScheme });
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
    if (view) await page.evaluate((attachmentView) => window.cmuxAcpmuxComposer?.({ attachmentView }), view);
    return page;
  }

  /// Pastes `count` PNG screenshots into the prompt, as ⌘V of copied images does.
  const pasteImages = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      const canvas = document.createElement("canvas");
      canvas.width = 1200;
      canvas.height = 800;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#101114";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      for (let index = 0; index < count; index += 1)
        data.items.add(new File([blob], `Screenshot ${index + 1}.png`, { type: "image/png" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      // Where the next key goes, at once: the prompt, not a stand-in that takes keys for a moment.
      return target.contains(document.activeElement);
    }, count);

  const promptText = (page: Page) =>
    page.locator(".acpmux-composer-prompt [contenteditable='true']").evaluate((node) => {
      // The prompt's text, without the attachments placed in it (each an atom in the line).
      const copy = node.cloneNode(true) as Element;
      for (const atom of copy.querySelectorAll("[data-inline-attachment]")) atom.remove();
      return copy.textContent?.replace(/\u00a0/g, " ");
    });

  test("keys typed while pasted images attach all land, spaces included", async () => {
    const page = await newChat();
    const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
    await prompt.click();
    await page.keyboard.type("i cant");
    expect(await pasteImages(page, 3)).toBe(true);
    // The person types on at once, while the images are still being read.
    await page.keyboard.type(" preview", { delay: 15 });
    await page.locator(".acpmux-md-inline-chip .acpmux-attachment-image").nth(2).waitFor();
    await page.keyboard.type(" them");
    expect(await promptText(page)).toBe("i cant preview them");
    await page.close();
  });

  test("the attachment strip is compact: one row of 64 px tiles close to the text", async () => {
    const page = await newChat("light", "strip");
    const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
    await prompt.click();
    const field = page.locator(".acpmux-composer-prompt").first();
    const before = (await page.locator(".acpmux-composer-box").boundingBox())!;
    await pasteImages(page, 3);
    const chips = page.locator(".acpmux-attachments .acpmux-attachment-image");
    await chips.nth(2).waitFor();
    // Every thumbnail loaded and sized by its own shape (decode() can reject while a thumbnail's
    // source is swapped for its smaller copy).
    await page.waitForFunction(() => {
      const images = [
        ...document.querySelectorAll<HTMLImageElement>(".acpmux-attachments .acpmux-attachment-image img"),
      ];
      return images.length === 3 && images.every((img) => img.complete && img.naturalWidth > 0);
    });
    const box = (await page.locator(".acpmux-composer-box").boundingBox())!;
    const strip = (await page.locator(".acpmux-attachments").boundingBox())!;
    const tiles = await Promise.all([0, 1, 2].map(async (i) => (await chips.nth(i).boundingBox())!));
    for (const tile of tiles) {
      expect(Math.round(tile.height)).toBe(64);
      // One row: every tile on the strip's first line.
      expect(Math.abs(tile.y - tiles[0]!.y)).toBeLessThan(1);
    }
    expect(Math.round(tiles[1]!.x - (tiles[0]!.x + tiles[0]!.width))).toBe(6);
    expect(Math.round(tiles[0]!.y - box.y)).toBe(8);
    // The text's first line starts 6 px under the strip.
    const textTop = await field.evaluate((node) => {
      const line = node.querySelector("[contenteditable='true']")!.getBoundingClientRect();
      return line.top;
    });
    expect(Math.round(textTop - (strip.y + strip.height))).toBe(6);
    // The strip adds at most 78 px to the composer.
    expect(box.height - before.height).toBeLessThanOrEqual(78);
    await page.close();
  });

  /// The mean luminance (0-255) of `pixels` [x, y] in a decoded screenshot.
  const luminance = (png: PNG, pixels: [number, number][]) =>
    pixels.reduce((sum, [x, y]) => {
      const at = (png.width * y + x) * 4;
      return sum + 0.2126 * png.data[at]! + 0.7152 * png.data[at + 1]! + 0.0722 * png.data[at + 2]!;
    }, 0) / pixels.length;

  // The strip's thumbnail (Leo's 56 px squares were the strip's); an inline thumbnail is sized to sit
  // in a line of text (markdownField.css).
  test("a dark screenshot's thumbnail is big enough to see and keeps a clear edge", async () => {
    const page = await newChat("dark", "strip");
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await pasteImages(page, 3);
    const chips = page.locator(".acpmux-attachments .acpmux-attachment-image");
    await chips.nth(2).waitFor();
    await page
      .locator(".acpmux-attachments .acpmux-attachment-image img")
      .nth(2)
      .evaluate((img: HTMLImageElement) => img.decode());
    for (let index = 0; index < 3; index += 1) {
      // Leo, 2026-10-14: 56 px squares cropped a wide screenshot to a sliver of its text. A thumbnail
      // shows the screenshot's own shape (3:2), tall enough to tell one from another.
      const box = (await chips.nth(index).boundingBox())!;
      expect(box.height).toBeGreaterThanOrEqual(60);
      expect(box.width / box.height).toBeGreaterThan(1.3);
      // The thumbnail with a 4 px margin of the composer around it.
      const png = PNG.sync.read(
        await page.screenshot({ clip: { x: box.x - 4, y: box.y - 4, width: box.width + 8, height: box.height + 8 } }),
      );
      const { width, height } = png;
      // Along the middle third of each side: the thumbnail's outermost pixel, the composer 3 px
      // outside it, and the image's own middle.
      const edge: [number, number][] = [];
      const outside: [number, number][] = [];
      for (let x = Math.floor(width / 3); x < (2 * width) / 3; x += 1) {
        edge.push([x, 4], [x, height - 5]);
        outside.push([x, 1], [x, height - 2]);
      }
      for (let y = Math.floor(height / 3); y < (2 * height) / 3; y += 1) {
        edge.push([4, y], [width - 5, y]);
        outside.push([1, y], [width - 2, y]);
      }
      const middle: [number, number][] = [];
      for (let x = Math.floor(width / 2) - 4; x < width / 2 + 4; x += 1)
        for (let y = Math.floor(height / 2) - 4; y < height / 2 + 4; y += 1) middle.push([x, y]);
      const [e, o, m] = [luminance(png, edge), luminance(png, outside), luminance(png, middle)];
      expect(Math.abs(e - o)).toBeGreaterThan(45);
      expect(Math.abs(e - m)).toBeGreaterThan(45);
    }
    await page.close();
  });
});
