// cmux-web-test-timeout: 300
// The New Tab widget view's Needs you card (newtab/WidgetCards.tsx): each chat is a row holding its
// open button and a small x that puts it away. A hover lights only the control under the pointer.
// The whole row took a wash around its small x, under the x's own fill (Leo 2026-10-27: "why are you
// giving it the entire row when it's only this small little section? Just don't do that. Don't ever do
// that."; rulebook: a hover or press highlight covers only the control it belongs to).
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-widget-chat-hover.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-widget-chat-hover.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new tab widget chat hover: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab widget chat hover", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "agent-pane.new-tab";
  const VARIANT = "widgets";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: VARIANT, frame: "component", width: 900, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: [...browsers.values()][0], params: { variant: VARIANT } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, theme: string): Promise<Page> => {
    // Reduced motion: hover fills apply in the hover's own frame, with no transition to wait out.
    const page = await browsers
      .get(engine)!
      .newPage({ viewport: { width: 900, height: 800 }, reducedMotion: "reduce" });
    await page.goto(stageURL(theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".nt-widget-chat").first().waitFor();
    return page;
  };

  const clear = (color: string) => color === "transparent" || /^rgba\(.*,\s*0\)$/.test(color);
  const fill = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => getComputedStyle(element).backgroundColor);

  for (const [engine] of engines)
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
      test(`${engine}, ${theme}: a Needs you chat lights only the control under the pointer`, async () => {
        const page = await open(engine, theme);
        const row = ".nt-widget-chat";
        const openButton = ".nt-widget-chat .nt-widget-chat-open";
        const dismiss = ".nt-widget-chat .nt-widget-dismiss";

        await page.locator(dismiss).first().hover();
        expect(clear(await fill(page, dismiss)), "the x lights under the pointer").toBe(false);
        expect(clear(await fill(page, row)), "hovering the x lights no row").toBe(true);
        expect(clear(await fill(page, openButton)), "hovering the x lights no open button").toBe(true);

        await page.locator(openButton).first().hover();
        expect(clear(await fill(page, openButton)), "the open button lights under the pointer").toBe(false);
        expect(clear(await fill(page, row)), "the row takes no wash of its own").toBe(true);
        expect(clear(await fill(page, dismiss)), "the x stays unlit beside a lit open button").toBe(true);
        // The open button's wash ends before the x: the x sits outside it.
        const [openBox, xBox] = await Promise.all([
          page.locator(openButton).first().boundingBox(),
          page.locator(dismiss).first().boundingBox(),
        ]);
        expect(openBox!.x + openBox!.width, "the open button's wash stops before the x").toBeLessThanOrEqual(xBox!.x);
        await page.close();
      });
});
