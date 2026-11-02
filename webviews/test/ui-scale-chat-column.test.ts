// Interface Scale is page zoom, and Agent Chat Zoom is a second page-zoom multiplier. The chat
// column and the New Tab composer should keep their on-screen width and inset at the product's
// effective zoom (#22257).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Box = { left: number; width: number };

await requireBrowserLane("ui-scale-chat-column.test.ts", async () => {
  const PANE = 843;
  const CASES = [
    { interfaceScale: 1, chatZoom: 1 },
    { interfaceScale: 1.25, chatZoom: 1 },
    { interfaceScale: 1.5, chatZoom: 1 },
    { interfaceScale: 1, chatZoom: 1.25 },
    { interfaceScale: 1.25, chatZoom: 1.25 },
  ] as const;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ui-scale-chat-column: skipping (run `bunx playwright install chromium`)");
    describe.skip("interface scale chat column", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  // Mirrors the native host's two inputs: WKWebView/Chromium receives the product page zoom while
  // the web page receives the same effective value as the sizing token and a change notification.
  // Keeping the inputs separate makes a uiScale-only publication fail the browser assertions.
  const publishNativePageZoom = async (page: Page, uiScale: number, chatZoom: number): Promise<void> => {
    await page.evaluate(
      ({ uiScale, pageZoom }) => {
        document.documentElement.style.setProperty("--cmux-ui-scale", String(pageZoom));
        document.documentElement.style.setProperty("--cmux-interface-scale", String(uiScale));
        window.dispatchEvent(new Event("cmux-ui-scale-change"));
      },
      { uiScale, pageZoom: uiScale * chatZoom },
    );
  };

  const open = async (entry: string, variant: string, uiScale: number, chatZoom: number): Promise<Page> => {
    const effectiveScale = uiScale * chatZoom;
    const page = await browser!.newPage({
      viewport: { width: Math.round(PANE / effectiveScale), height: Math.round(900 / effectiveScale) },
      deviceScaleFactor: effectiveScale,
    });
    await page.goto(url(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await publishNativePageZoom(page, uiScale, chatZoom);
    return page;
  };

  const measure = async (page: Page, selector: string, effectiveScale: number): Promise<Box> => {
    const target = page.locator(selector).first();
    await target.waitFor();
    const box = await target.boundingBox();
    if (!box) throw new Error(`missing ${selector}`);
    return { left: box.x * effectiveScale, width: box.width * effectiveScale };
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.chat-width", "agent-pane.new-tab"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the chat column and New Tab composer keep their 800px measure across scale combinations", async () => {
    for (const { interfaceScale, chatZoom } of CASES) {
      const effectiveScale = interfaceScale * chatZoom;
      const chat = await open("agent-pane.chat-width", "standard", interfaceScale, chatZoom);
      const chatBox = await measure(chat, ".acpmux-row", effectiveScale);
      await chat.close();
      expect(chatBox.width, `chat width at ${interfaceScale} x ${chatZoom}`).toBeCloseTo(800, -0.5);
      expect(chatBox.left, `chat inset at ${interfaceScale} x ${chatZoom}`).toBeCloseTo(21.5, -0.5);

      const newTab = await open("agent-pane.new-tab", "chats-unavailable", interfaceScale, chatZoom);
      const newTabBox = await measure(newTab, ".nt-box", effectiveScale);
      await newTab.close();
      expect(newTabBox.width, `New Tab width at ${interfaceScale} x ${chatZoom}`).toBeCloseTo(800, -0.5);
      expect(newTabBox.left, `New Tab inset at ${interfaceScale} x ${chatZoom}`).toBeCloseTo(21.5, -0.5);
    }
  });

  test("a native-style scale update keeps the live column geometry in sync", async () => {
    const effectiveScale = 1.5 * 1.25;
    const page = await open("agent-pane.chat-width", "standard", 1, 1);
    const before = await measure(page, ".acpmux-row", 1);
    await page.setViewportSize({ width: Math.round(PANE / effectiveScale), height: Math.round(900 / effectiveScale) });
    await publishNativePageZoom(page, 1.5, 1.25);
    const after = await measure(page, ".acpmux-row", effectiveScale);
    await page.close();
    expect(before.width).toBeCloseTo(800, -0.5);
    expect(after.width).toBeCloseTo(800, -0.5);
    expect(after.left).toBeCloseTo(21.5, -0.5);
  });
});
