// New Tab's top area is condensed (op-next-toolbar, from the UI coordinator): the space above the
// composer card was clamp(40px, 14vh, 140px), 112 px in a 1280x800 window, and the card's
// folder / host / branch strip was 30 px tall in detail type. Both read as too much chrome over
// the card. Now the gap above the card is about half, and the strip on the New Tab card is 24 px
// in caption type. The chat composer's strip (composerLocation.css) keeps its own size.
// This measures the real gallery stage in Chromium at 1280x800.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-top-area.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-top-area: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab top area", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=agent-pane.new-tab&variant=${variant}`;

  async function ready(page: Page) {
    for (;;) {
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        return;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  }

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 900, height: 600 } });
    await warm.goto(url("empty"));
    await ready(warm);
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("at 1280x800 the card sits closer to the top and its location strip is 24 px", async () => {
    const page = await browser!.newPage({ viewport: { width: 1280, height: 800 } });
    await page.goto(url("empty"));
    await ready(page);
    await page.locator(".nt-composer .acpmux-composer-strip").first().waitFor();
    const geometry = await page.evaluate(() => {
      const screen = document.querySelector<HTMLElement>(".nt-screen")!;
      const strip = document.querySelector<HTMLElement>(".nt-composer .acpmux-composer-strip")!;
      return {
        stripTop: Math.round(strip.getBoundingClientRect().top - screen.getBoundingClientRect().top),
        stripHeight: Math.round(strip.getBoundingClientRect().height),
        // The strip's own type and every control's in it (the ghost buttons set their own).
        stripFontSize: Math.max(
          ...[strip, ...strip.querySelectorAll<HTMLElement>("button, .acpmux-location-readonly")].map((node) =>
            parseFloat(getComputedStyle(node).fontSize),
          ),
        ),
      };
    });
    await page.close();
    console.log("new-tab-top-area geometry", JSON.stringify(geometry));
    expect({
      // Was 112 (14vh of 800).
      topCondensed: geometry.stripTop <= 64,
      // Was 30.
      stripCondensed: geometry.stripHeight <= 24,
      // Was 12 (--text-detail); now --text-caption.
      captionType: geometry.stripFontSize <= 11,
    }).toEqual({ topCondensed: true, stripCondensed: true, captionType: true });
  });
});
