// Interface Scale (#22257): the app zooms the page (WKWebView.pageZoom) and sets --cmux-ui-scale on
// the root. The New Tab page and the chat column keep their on-screen width at a larger scale
// instead of stretching across the pane. Modeled as narrow-layouts.test.ts models pageZoom: the page
// lays out in width / scale CSS px, drawn at scale.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("ui-scale-column-layout.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("ui-scale-column-layout: skipping (run `bunx playwright install chromium`)");
    describe.skip("ui scale column layout", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const PANE = 843;
  /** The on-screen left edge and width (points) of `selector` in a PANE-point pane at `scale`. */
  const measure = async (entry: string, variant: string, selector: string, scale: number) => {
    const page = await browser!.newPage({
      viewport: { width: Math.round(PANE / scale), height: Math.round(900 / scale) },
      deviceScaleFactor: scale,
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 1; ; attempt++) {
      await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=${entry}&variant=${variant}`);
      try {
        await page.waitForFunction(() => {
          const ready = document.documentElement.dataset.galleryReady;
          return ready === "1" || ready === "error";
        });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    // What DesignSettings.interfaceScaleScript sets alongside pageZoom.
    await page.evaluate((value) => document.documentElement.style.setProperty("--cmux-ui-scale", value), String(scale));
    await page.waitForSelector(selector);
    const box = await page.evaluate((query) => {
      const rect = document.querySelector(query)!.getBoundingClientRect();
      return { left: rect.left, width: rect.width };
    }, selector);
    await page.close();
    return { left: box.left * scale, width: box.width * scale };
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [name, entry, variant, selector] of [
    ["the New Tab composer", "agent-pane.new-tab", "chats-unavailable", ".nt-box"],
    ["the chat column", "agent-pane.narrow", "code", ".acpmux-row"],
  ] as const)
    test(`${name} keeps its on-screen width at interface scale 1.5`, async () => {
      const base = await measure(entry, variant, selector, 1);
      const scaled = await measure(entry, variant, selector, 1.5);
      expect(Math.abs(scaled.width - base.width)).toBeLessThan(2);
      expect(Math.abs(scaled.left - base.left)).toBeLessThan(2);
    });
});
