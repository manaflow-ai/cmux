// New Tab scrolls in one place (Leo 2026-10-12): the page had two scrollbars, the page's own at
// the window edge and the Chats list's inside it, and the list was cut mid-row right above the
// template dots. Now, as in Settings (cx-jh7kq), a page with the All chats list scrolls only in
// that list, the document never scrolls, and the list's edges fade instead of slicing a row.
// This measures the real gallery stages in Chromium in a short window (360 px), where the list's
// minimum height pushed the page past the window.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-scroll: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab scroll", () => test("chromium", () => {}));
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

  /** Every element that scrolls now (scrollable overflow and more content than room), and the list's edge mask. */
  async function look(variant: string) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 360 } });
    await page.goto(url(variant));
    await ready(page);
    await page.locator(".nt-screen").first().waitFor();
    if (variant === "many-chats") await page.locator(".nt-all-item:not(.is-loader)").first().waitFor();
    const state = await page.evaluate(() => {
      const scrollers = [...document.querySelectorAll<HTMLElement>(".nt-screen, .nt-screen *")].filter((node) => {
        const overflow = getComputedStyle(node).overflowY;
        return (overflow === "auto" || overflow === "scroll") && node.scrollHeight > node.clientHeight + 1;
      });
      const doc = document.scrollingElement!;
      const fades = (node: HTMLElement) => {
        const style = getComputedStyle(node);
        return (style.maskImage || style.getPropertyValue("-webkit-mask-image")).includes("gradient");
      };
      return {
        documentScrolls: doc.scrollHeight > doc.clientHeight + 1,
        scrollers: scrollers.map((node) => node.classList[node.classList.length - 1] ?? node.tagName),
        fades: scrollers.map(fades),
      };
    });
    await page.close();
    return state;
  }

  test("with All chats, the list is the page's only scroller and its edges fade", async () => {
    expect(await look("many-chats")).toEqual({ documentScrolls: false, scrollers: ["nt-all-list"], fades: [true] });
  });

  test("the calm default scrolls in one place, and fades there too", async () => {
    // The page itself scrolls here (no list of its own): it too ends in a fade, not a cut row.
    expect(await look("calm-default")).toEqual({ documentScrolls: false, scrollers: ["nt-screen"], fades: [true] });
  });
});
