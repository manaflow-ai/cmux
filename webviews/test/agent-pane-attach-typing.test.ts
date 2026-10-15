// Leo, 2026-10-13 (cosmic-gray), two bugs in pasting screenshots into the composer:
//
// - Typing on while pasted images attach lost a keystroke, so
// "i cant" + space + "preview" sent "i cantpreview". A paste of only images took the keys for 50 ms
// (ProseMirror's paste capture), and the space typed then came back stripped. The keys typed while
// pasted images attach all land, in order, in the prompt.
// - A dark screenshot's thumbnail was the composer's own dark, so the 2nd and 3rd looked missing. A
//   thumbnail draws a hairline edge over its image, so any image reads as a thumbnail. The page is the pane's dev entry with the in-page mock transport.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function newChat(colorScheme: "light" | "dark" = "light"): Promise<Page> {
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
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable]")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      // Where the next key goes, at once: the prompt, not a stand-in that takes keys for a moment.
      return target.contains(document.activeElement);
    }, count);

  const promptText = (page: Page) =>
    page
      .locator(".acpmux-composer-prompt [contenteditable]")
      .evaluate((node) => node.textContent?.replace(/\u00a0/g, " "));

  test("keys typed while pasted images attach all land, spaces included", async () => {
    const page = await newChat();
    const prompt = page.locator(".acpmux-composer-prompt [contenteditable]");
    await prompt.click();
    await page.keyboard.type("i cant");
    expect(await pasteImages(page, 3)).toBe(true);
    // The person types on at once, while the images are still being read.
    await page.keyboard.type(" preview", { delay: 15 });
    await page.locator(".acpmux-attachment-image").nth(2).waitFor();
    await page.keyboard.type(" them");
    expect(await promptText(page)).toBe("i cant preview them");
    await page.close();
  });

  /// The mean luminance (0-255) of `pixels` [x, y] in a decoded screenshot.
  const luminance = (png: PNG, pixels: [number, number][]) =>
    pixels.reduce((sum, [x, y]) => {
      const at = (png.width * y + x) * 4;
      return sum + 0.2126 * png.data[at]! + 0.7152 * png.data[at + 1]! + 0.0722 * png.data[at + 2]!;
    }, 0) / pixels.length;

  test("a dark screenshot's thumbnail shows an edge against the dark composer", async () => {
    const page = await newChat("dark");
    await page.locator(".acpmux-composer-prompt [contenteditable]").click();
    await pasteImages(page, 3);
    const chips = page.locator(".acpmux-attachment-image");
    await chips.nth(2).waitFor();
    await page
      .locator(".acpmux-attachment-image img")
      .nth(2)
      .evaluate((img: HTMLImageElement) => img.decode());
    for (let index = 0; index < 3; index += 1) {
      const png = PNG.sync.read(await chips.nth(index).screenshot());
      const { width, height } = png;
      // The middle third of each side, its outermost pixel (clear of the rounded corners), against the
      // image's own middle.
      const edge: [number, number][] = [];
      for (let x = Math.floor(width / 3); x < (2 * width) / 3; x += 1) edge.push([x, 0], [x, height - 1]);
      for (let y = Math.floor(height / 3); y < (2 * height) / 3; y += 1) edge.push([0, y], [width - 1, y]);
      const middle: [number, number][] = [];
      for (let x = width / 2 - 4; x < width / 2 + 4; x += 1)
        for (let y = height / 2 - 4; y < height / 2 + 4; y += 1) middle.push([x, y]);
      expect(Math.abs(luminance(png, edge) - luminance(png, middle))).toBeGreaterThan(12);
    }
    await page.close();
  });
});
