// cmux-web-test-timeout: 300
// The model picker's harness rail is plain icons on a round wash, matching the composer's round
// pills, never a column of square tiles (Leo 2026-10-18: "grid squares"). The selected harness and a
// hovered one both take that round wash.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/model-picker-round-rail.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}&frame=component&width=760&theme=Catppuccin+Mocha`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    for (const [name, engine] of engines) {
      const browser = await engine.launch({ headless: true });
      browsers.set(name, browser);
      // The first load can run Vite's dependency optimizer and reload mid-compile.
      const warm = await browser.newPage({ viewport: { width: 760, height: 600 } });
      await warm.goto(stageURL("agent-pane.new-tab", "reasoning-chip"));
      for (;;) {
        try {
          await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      await warm.close();
    }
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
    return page;
  };
  /** A real press and release at the centre of `selector`. */
  const press = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await page.waitForTimeout(300);
  };

  for (const [engine] of engines)
    test(`${engine}: every rail tab is round, the selected one included`, async () => {
      const page = await open(engine);
      await press(page, chip("Model"));
      await page.locator(".acpmux-mp-rail-tab").first().waitFor();
      const tabs = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-mp-rail-tab")].map((tab) => {
          const box = tab.getBoundingClientRect();
          const style = getComputedStyle(tab);
          return {
            name: tab.getAttribute("aria-label") ?? tab.textContent?.trim() ?? "",
            selected: tab.getAttribute("aria-selected") === "true",
            round: parseFloat(style.borderTopLeftRadius) >= Math.min(box.width, box.height) / 2 - 0.5,
            filled: style.backgroundColor !== "rgba(0, 0, 0, 0)",
          };
        }),
      );
      expect(tabs.length, "the rail shows its tabs").toBeGreaterThan(1);
      expect(
        tabs.filter((tab) => !tab.round).map((tab) => tab.name),
        "square tabs",
      ).toEqual([]);
      expect(
        tabs.some((tab) => tab.selected && tab.filled),
        "the selected harness keeps its wash",
      ).toBe(true);
      await page.close();
    });
});
