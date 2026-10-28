// The model menu on a New Tab page stays inside what the page shows (cx-m6jn0; dogfood run 4, a
// 1100x720 window: the menu opened below the chip at the window's height while the New Tab
// scroller cut it off above the template pager, so its last rows and More models were out of
// reach). Since Leo 2026-10-20 the model button opens its compact menu (models, Effort, More models,
// Account, Fast mode) in every composer, New Tab's included; that menu shows whole inside the page.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-picker-clip.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-picker-clip: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab picker clip", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  // The pane's utility classes, compiled as the app build does (Vite's plugin compiles none for
  // an entry with `source(none)`).
  let utilities = "";
  beforeAll(async () => {
    const { compileTailwind } = await import("../scripts/agent-pane/tailwindCompile.mjs");
    utilities = await compileTailwind(path.join(webviews, "src/agent-session/acpmux/tailwind.css"));
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/new-tab-picker.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the New Tab model menu shows whole inside the page's scroller, above the pager", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html`);
    await page.addStyleTag({ content: utilities });
    const chip = page.locator(".acpmux-model-name").first();
    await chip.waitFor();
    await chip.click();
    const menu = page.locator(".acpmux-quick-menu");
    await menu.waitFor();
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-quick-menu");
      return !!node && getComputedStyle(node).visibility === "visible";
    });
    const geometry = await page.evaluate(() => {
      const menu = document.querySelector(".acpmux-quick-menu")!.getBoundingClientRect();
      const screenNode = document.querySelector<HTMLElement>(".nt-screen")!;
      const screen = screenNode.getBoundingClientRect();
      return {
        menuTop: menu.top,
        menuBottom: menu.bottom,
        menuHeight: menu.height,
        screenTop: screen.top,
        screenBottom: screen.bottom,
        // How far the page's scroller can still scroll down.
        scrollable: screenNode.scrollHeight - screenNode.clientHeight - screenNode.scrollTop,
      };
    });
    console.log("new-tab-picker-clip geometry", JSON.stringify(geometry));
    const { menuTop, menuBottom, menuHeight, screenTop, screenBottom, scrollable } = geometry;
    // Never collapsed: it lists its rows.
    expect(menuHeight).toBeGreaterThan(60);
    // Never off the top of the page, where nothing scrolls to it.
    expect(menuTop).toBeGreaterThanOrEqual(screenTop);
    // Inside the page, or the page scrolls to its end.
    if (menuBottom > screenBottom) expect(scrollable).toBeGreaterThanOrEqual(Math.floor(menuBottom - screenBottom));
    // The menu shows whole: no ancestor clips it (cx-qe8fn). A clipping card (.nt-box with
    // overflow: hidden, before 4b35f13b) cut it at the card's top or bottom edge in the app, and
    // scrolled the card's own rows. Hit-test both edges, with the page scrolled
    // to the menu.
    const painted = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-quick-menu")!;
      node.scrollIntoView({ block: "nearest" });
      const rect = node.getBoundingClientRect();
      const x = rect.left + rect.width / 2;
      const hits = (y: number) => node.contains(document.elementFromPoint(x, y));
      return {
        top: hits(rect.top + 4),
        bottom: hits(rect.bottom - 4),
        cardScrollTop: document.querySelector<HTMLElement>(".nt-box")!.scrollTop,
      };
    });
    expect(painted).toEqual({ top: true, bottom: true, cardScrollTop: 0 });
    await page.close();
  });
});
