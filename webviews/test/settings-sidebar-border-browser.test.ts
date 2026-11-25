// cmux-web-test-timeout: 600
// l10n-allow-file: browser test diagnostics, not shipped UI.
// cmux#48617 ("where is the border for the sidebar for the cmux settings in cmux next"): Settings drew
// no line between its categories and the content. The refined look (look.css) cleared the sidebar's
// edge and parted the columns by the sidebar's fill alone, but by default (One Color) that fill is
// none and over a picture both columns are the picture, so nothing parted them. Real Chromium lays out
// the Settings gallery page and holds the sidebar's edge to the window sidebar's resting line: the
// chrome divider (--cmux-chrome-divider) at the width the host sends (--cmux-sidebar-border-width,
// 1px when it sends none), none when the host turns it off, and none on the stacked narrow strip.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("settings-sidebar-border-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("settings-sidebar-border: chromium cannot launch here; skipping");
    describe.skip("settings sidebar border", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.settings", { browser, params: { variant: "general" } });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const origin = () => `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;

  async function open(colorScheme: "light" | "dark", width: number): Promise<Page> {
    const height = 640;
    const page = await browser!.newPage({ viewport: { width, height }, reducedMotion: "reduce" });
    await page.goto(`${origin()}${galleryFrame("pages.settings", { variant: "general", colorScheme, width, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(".settings > .sidebar");
    return page;
  }

  /** The sidebar's right edge as drawn, and the divider token it should draw, both resolved by the page. */
  const edge = (page: Page) =>
    page.evaluate(() => {
      const sidebar = document.querySelector(".settings > .sidebar")!;
      const style = getComputedStyle(sidebar);
      const probe = document.createElement("div");
      probe.style.color = "var(--ds-color-divider)";
      sidebar.append(probe);
      const divider = getComputedStyle(probe).color;
      probe.remove();
      return {
        width: Number.parseFloat(style.borderRightWidth),
        style: style.borderRightStyle,
        color: style.borderRightColor,
        divider,
      };
    });

  for (const colorScheme of ["light", "dark"] as const) {
    test(`a wide pane (${colorScheme}) parts the sidebar from the content by the chrome divider`, async () => {
      const page = await open(colorScheme, 1000);
      try {
        const line = await edge(page);
        expect(line.style).toBe("solid");
        expect(line.width).toBe(1);
        expect(line.color).toBe(line.divider);
        expect(line.color).not.toMatch(/rgba\(\d+, \d+, \d+, 0\)|transparent/);
      } finally {
        await page.close();
      }
    });
  }

  test("the line takes the host's resting width, and none when the host turns it off", async () => {
    const page = await open("dark", 1000);
    try {
      await page.evaluate(() => document.documentElement.style.setProperty("--cmux-sidebar-border-width", "2px"));
      expect((await edge(page)).width).toBe(2);
      await page.evaluate(() => document.documentElement.style.setProperty("--cmux-sidebar-border-width", "0px"));
      expect((await edge(page)).width).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("while the window's sidebar is hidden the line fades, as the section list's edge always did", async () => {
    const page = await open("light", 1000);
    try {
      // The pointer off the list (it rests at 0,0, over the sidebar), so the list is not hovered.
      await page.mouse.move(800, 320);
      await page.evaluate(() => (document.documentElement.dataset.appSidebar = "hidden"));
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".settings > .sidebar")!).borderRightColor === "rgba(0, 0, 0, 0)",
      );
      expect((await edge(page)).color).toBe("rgba(0, 0, 0, 0)");
      // Over the list it comes back.
      await page.mouse.move(100, 320);
      await page.waitForFunction(
        () => getComputedStyle(document.querySelector(".settings > .sidebar")!).borderRightColor !== "rgba(0, 0, 0, 0)",
      );
    } finally {
      await page.close();
    }
  });

  test("a narrow pane's stacked strip keeps no side line", async () => {
    const page = await open("light", 480);
    try {
      expect((await edge(page)).width).toBe(0);
    } finally {
      await page.close();
    }
  });
});
