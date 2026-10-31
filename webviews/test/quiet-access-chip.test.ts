// cmux-web-test-timeout: 300
// The permission chip is quiet, like Claude's mode label (Leo 2026-10-18): Full access draws in the
// footer's mode tone (--agent-soft, as every mode does since #22667; the model and effort are the
// muted label beside it), not a warning-colored shield and label that sit in the composer all the time. The shield's "!" mark still names the risk, and the menu keeps the warning
// color on Full access's icon, where the mode is chosen.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/quiet-access-chip.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("quiet-access-chip.test.ts", async () => {
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
      console.warn(`quiet-access-chip: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("quiet access chip", () => test("browsers", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.composer", {
      browser: [...browsers.values()][0],
      params: { variant: "access-menu-codex" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const trigger = ".acpmux-access .acpmux-picker-button";
  /** Until no menu is still opening or closing and no transition is running (Base UI unmounts a
   *  closed menu, and hands focus back, once its fade has finished), and two frames have painted. */
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const moving = document.querySelector("[data-starting-style], [data-ending-style]");
        if (!moving && finite().every((animation) => animation.playState !== "running")) return;
      }
    });
  /** The composer's Codex access-menu stage with Full access picked and the menu closed. */
  const fullAccess = async (engine: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(stageURL("agent-pane.composer", "access-menu-codex"));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    // The stage's play leaves the menu open.
    if (!(await page.locator("[role=menuitemradio]").count())) await page.locator(trigger).click();
    await page.locator('[role=menuitemradio]:has-text("Full access")').first().click();
    await page.locator(".acpmux-access.acpmux-unrestricted").waitFor();
    // The menu hands focus back to its chip after its close fade; blur after that, so the chip shows
    // its resting color, not its focus step.
    await page.locator("[role=menuitemradio]").first().waitFor({ state: "detached" });
    await settled(page);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(2, 2);
    await settled(page);
    return page;
  };

  for (const [engine] of engines) {
    test(`${engine}: Full access draws in the mode's quiet tone`, async () => {
      const page = await fullAccess(engine);
      const colors = await page.evaluate((selector) => {
        const access = document.querySelector<HTMLElement>(selector)!;
        const model = document.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button")!;
        return {
          access: getComputedStyle(access).color,
          shield: getComputedStyle(access.querySelector("svg")!).color,
          model: getComputedStyle(model).color,
          // The footer's mode tone, resolved where the chip draws.
          soft: (() => {
            const probe = document.createElement("span");
            probe.style.color = "var(--agent-soft)";
            access.parentElement!.append(probe);
            const color = getComputedStyle(probe).color;
            probe.remove();
            return color;
          })(),
        };
      }, trigger);
      expect(colors.access).toBe(colors.soft);
      expect(colors.shield).toBe(colors.soft);
      await page.close();
    });

    test(`${engine}: the menu still marks Full access's icon in the warning color`, async () => {
      const page = await fullAccess(engine);
      await page.locator(trigger).click();
      const row = page.locator('[role=menuitemradio]:has-text("Full access")').first();
      await row.waitFor();
      const colors = await row.evaluate((node) => ({
        icon: getComputedStyle(node.querySelector(".acpmux-access-item-icon")!).color,
        text: getComputedStyle(node).color,
      }));
      expect(colors.icon).not.toBe(colors.text);
      await page.close();
    });
  }
});
