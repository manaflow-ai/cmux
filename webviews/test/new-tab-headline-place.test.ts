// cmux-web-test-timeout: 420
// New Tab's composer keeps its place now that the page has no greeting (Leo 2026-10-22) and no
// headline or other widgets (Lawrence 2026-11-09: "remove widgets completely"). Under the old
// greeting the composer's top sat the greeting's box (its heading line and the 6px under it) plus
// the page's gap below the page's top padding; removing them must not lift it
// (screen.css .nt-composer-room).
//
// Real Chromium on the gallery's dev server; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-headline-place.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-headline-place: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab headline place", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRIES = ["agent-pane.new-tab"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRIES, { browser, timeoutMs: 240_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// One gallery stage, ready (or failed), in its own page.
  async function open(entry: string, params: Record<string, string>): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, params)}`);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryReady), undefined, {
      timeout: 90_000,
    });
    return page;
  }

  /// Where the composer's top sits under the page's top padding, and the old greeting's box: its
  /// heading line plus the 6px under it plus the page's gap (what the composer sat under).
  const place = (page: Page) =>
    page.evaluate(() => {
      const screen = document.querySelector<HTMLElement>(".nt-screen")!;
      const style = getComputedStyle(screen);
      const probe = document.createElement("p");
      probe.style.lineHeight = "var(--text-heading--line-height)";
      screen.append(probe);
      const heading = parseFloat(getComputedStyle(probe).lineHeight);
      probe.remove();
      const composer = document.querySelector(".nt-composer")!.getBoundingClientRect().top;
      return {
        minimal: screen.hasAttribute("data-minimal"),
        offset: composer - screen.getBoundingClientRect().top - parseFloat(style.paddingTop),
        old: heading + 6 + parseFloat(style.rowGap),
      };
    });

  test("the composer sits where it sat under the greeting", async () => {
    const page = await open("agent-pane.new-tab", { variant: "minimal-default" });
    try {
      expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
      const measured = await place(page);
      console.log("new-tab-headline-place", JSON.stringify(measured));
      expect(measured.minimal).toBe(true);
      expect(Math.abs(measured.offset - measured.old)).toBeLessThan(0.5);
    } finally {
      await page.close();
    }
  });
});
