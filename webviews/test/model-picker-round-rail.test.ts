// cmux-web-test-timeout: 300
// The model picker's harness rail is a column of readable harness rows (#25796, #26071: Leo's
// "readable harness choices"), each its mark and its whole name, on a rounded wash, never the
// square tiles of 2026-10-18 ("grid squares"). The selected harness and a hovered one both take
// that wash. The model button opens its compact menu in every composer (Leo 2026-10-20: one model
// button), so the rail checked is that menu's.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/model-picker-round-rail.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-picker-round-rail.test.ts", async () => {
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
      console.warn(`model picker round rail: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("model picker round rail", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.new-tab", {
      browser: [...browsers.values()][0],
      params: { variant: "reasoning-chip" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const chip = (name: string) => `button[aria-haspopup][aria-label="${name}"]`;
  const open = async (engine: string, entry = "agent-pane.new-tab", variant = "reasoning-chip"): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await page.goto(stageURL(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await installPaintedFrames(page);
    return page;
  };
  /// Waits for the page to come to rest: its finite animations and transitions have finished, then
  /// two frames have painted, so what is read next is laid out as drawn.
  const atRest = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
  /** A real press and release at the centre of `selector`. */
  const press = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await atRest(page);
  };

  for (const [engine] of engines)
    test(`${engine}: every rail tab is a readable rounded row, the selected one included`, async () => {
      const page = await open(engine);
      await press(page, chip("Model"));
      await page.locator(".acpmux-quick-rail-tab").first().waitFor();
      const tabs = await page.evaluate(() => {
        const corner = (node: Element) => parseFloat(getComputedStyle(node).borderTopLeftRadius);
        return [...document.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab")].map((tab) => {
          const name = tab.querySelector<HTMLElement>(".acpmux-quick-harness-name");
          return {
            name: tab.getAttribute("aria-label") ?? "",
            shown: name?.textContent?.trim() ?? "",
            clipped: name ? name.scrollWidth > name.clientWidth + 1 : true,
            corner: corner(tab),
            selected: tab.getAttribute("aria-pressed") === "true",
            filled: getComputedStyle(tab).backgroundColor !== "rgba(0, 0, 0, 0)",
          };
        });
      });
      expect(tabs.length, "the rail shows its tabs").toBeGreaterThan(1);
      expect(
        tabs.filter((tab) => tab.shown !== tab.name || tab.clipped).map((tab) => tab.name),
        "tabs that do not show their whole name",
      ).toEqual([]);
      expect(
        tabs.filter((tab) => tab.corner < 4).map((tab) => `${tab.name}: ${tab.corner}`),
        "square tabs",
      ).toEqual([]);
      expect(
        tabs.some((tab) => tab.selected && tab.filled),
        "the selected harness keeps its wash",
      ).toBe(true);
      await page.close();
    });
});
