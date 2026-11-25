// New Tab uses one page scroll. The All chats list that once scrolled with it was the Threads
// template's, which cmux no longer ships (Leo 2026-11-18); its own gallery is agent-pane.all-chats-list.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant })}`;

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
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "empty" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Every element that scrolls now (scrollable overflow and more content than room), and the list's edge mask. */
  async function look(variant: string, height = 360) {
    const page = await browser!.newPage({ viewport: { width: 900, height } });
    await page.goto(url(variant));
    await ready(page);
    await page.locator(".nt-screen").first().waitFor();
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
      const screen = document.querySelector<HTMLElement>(".nt-screen")!;
      const overflowY = getComputedStyle(screen).overflowY;
      return {
        documentScrolls: doc.scrollHeight > doc.clientHeight + 1,
        scrollers: scrollers.map((node) => node.classList[node.classList.length - 1] ?? node.tagName),
        fades: scrollers.map(fades),
        pageFades: fades(screen),
        reachable: screen.scrollHeight <= screen.clientHeight + 1 || overflowY === "auto" || overflowY === "scroll",
      };
    });
    await page.close();
    return state;
  }

  test("the default page scrolls in one place at most, and never fades the page", async () => {
    const calm = await look("minimal-default");
    expect({
      documentScrolls: calm.documentScrolls,
      one: calm.scrollers.length <= 1,
      pageFades: calm.pageFades,
    }).toEqual({
      documentScrolls: false,
      one: true,
      pageFades: false,
    });
  });
});
