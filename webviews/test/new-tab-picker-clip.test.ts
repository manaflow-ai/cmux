// The model menu on a New Tab page stays inside what the page shows (cx-m6jn0; dogfood run 4, a
// 1100x720 window: the menu opened below the chip at the window's height while the New Tab
// scroller cut it off above the template pager, so its last rows and More models were out of
// reach). A menu sized to its scroller lists the rest by scrolling inside it.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the New Tab model menu ends inside the page's scroller, above the pager", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html`);
    await page.addStyleTag({ content: utilities });
    const chip = page.locator(".acpmux-model-name").first();
    await chip.waitFor();
    await chip.click();
    const menu = page.locator(".acpmux-mp[role=dialog]");
    await menu.waitFor();
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-mp[role=dialog]");
      return !!node && getComputedStyle(node).visibility === "visible";
    });
    const { menuBottom, screenBottom, menuTop, screenTop } = await page.evaluate(() => {
      const menu = document.querySelector(".acpmux-mp[role=dialog]")!.getBoundingClientRect();
      const screen = document.querySelector(".nt-screen")!.getBoundingClientRect();
      return { menuBottom: menu.bottom, screenBottom: screen.bottom, menuTop: menu.top, screenTop: screen.top };
    });
    expect(menuTop).toBeGreaterThanOrEqual(screenTop);
    expect(menuBottom).toBeLessThanOrEqual(screenBottom);
    await page.close();
  });
});
