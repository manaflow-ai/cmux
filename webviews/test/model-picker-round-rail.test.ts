// cmux-web-test-timeout: 300
// The model picker's harness rail: each tab shows its harness's symbol (the default symbols row at
// the top; Leo 2026-10-30: "we had a pretty good thing going with teh symbols of the harneses at
// the top") or its whole readable name (#25796, #26071), on a rounded wash, never the square tiles
// of 2026-10-18 ("grid squares"). The selected harness and a hovered one both take that wash. The model button opens its compact menu in every composer (Leo 2026-10-20: one model
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
      await page.locator(".acpmux-cols-tab[role=tab]").first().waitFor();
      const tabs = await page.evaluate(() => {
        const corner = (node: Element) => parseFloat(getComputedStyle(node).borderTopLeftRadius);
        const harnessTabs = [...document.querySelectorAll<HTMLElement>(".acpmux-cols-tab[role=tab]")];
        const add = document.querySelector<HTMLElement>(".acpmux-cols-tab-add");
        return {
          harnesses: harnessTabs.map((tab) => {
            const symbol = tab.querySelector(".agent-mark, .acpmux-cols-initial, svg");
            return {
              // Starred has its star; each harness has its mark or initial. The accessible
              // label and tooltip name the icon-only tab.
              symbol: !!symbol,
              markHeight: tab.querySelector(".agent-mark, svg")?.getBoundingClientRect().height,
              name: tab.getAttribute("aria-label") ?? "",
              title: tab.title,
              clipped: tab.scrollWidth > tab.clientWidth + 1 || tab.scrollHeight > tab.clientHeight + 1,
              corner: corner(tab),
              selected: tab.getAttribute("aria-selected") === "true",
              filled: getComputedStyle(tab).backgroundColor !== "rgba(0, 0, 0, 0)",
            };
          }),
          add: add
            ? {
                name: add.getAttribute("aria-label"),
                corner: corner(add),
              }
            : undefined,
        };
      });
      expect(tabs.harnesses.length, "the rail shows its harness tabs").toBeGreaterThan(1);
      expect(tabs.harnesses[0]?.name, "Starred is the first tab").toBe("Starred");
      expect(
        tabs.harnesses.some((tab) => tab.markHeight !== undefined),
        "the rail draws harness marks",
      ).toBe(true);
      expect(
        tabs.harnesses.every((tab) => tab.markHeight === undefined || tab.markHeight <= 16),
        "rail marks stay compact",
      ).toBe(true);
      expect(tabs.add, "the rail keeps an accessible Add harness action").toMatchObject({ name: "Add harness…" });
      expect(tabs.add?.corner ?? 0, "the Add harness action is rounded").toBeGreaterThanOrEqual(4);
      expect(
        tabs.harnesses
          .filter((tab) => !tab.symbol || !tab.name || !tab.title.includes(tab.name) || tab.clipped)
          .map((tab) => tab.name),
        "tabs without an unclipped symbol and accessible name",
      ).toEqual([]);
      expect(
        tabs.harnesses.filter((tab) => tab.corner < 4).map((tab) => `${tab.name}: ${tab.corner}`),
        "square tabs",
      ).toEqual([]);
      expect(
        tabs.harnesses.some((tab) => tab.selected && tab.filled),
        "the selected harness keeps its wash",
      ).toBe(true);
      await page.close();
    });
});
