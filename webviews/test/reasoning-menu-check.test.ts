// cmux-web-test-timeout: 300
// The effort levels mark the chosen one with a check at the row's trailing edge, as Claude's model
// list does, never in a leading gutter that indents every label (Leo 2026-10-18): each label starts
// at the row's own inset. The levels are the Effort submenu of the model button's menu (Leo
// 2026-10-20: one model button, no separate Reasoning chip). The stage is a new chat's composer,
// which keeps that submenu: on New Tab and in a live chat the current model's row carries its
// levels inline instead (#26521), and reasoning-own-control covers those.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/reasoning-menu-check.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reasoning-menu-check.test.ts", async () => {
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
      console.warn(`reasoning menu check: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("reasoning menu check", () => test("browsers", () => {}));
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
      params: { variant: "new-chat-reasoning" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const chip = (name: string) => `button[aria-haspopup][aria-label="${name}"]`;
  const open = async (engine: string, entry = "agent-pane.composer", variant = "new-chat-reasoning"): Promise<Page> => {
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
  };

  for (const [engine] of engines)
    test(`${engine}: the check trails the chosen row; labels start at the row's inset`, async () => {
      const page = await open(engine);
      await press(page, chip("Model"));
      await page.locator(".acpmux-quick-menu").first().waitFor();
      await page.getByRole("menuitem", { name: /^Effort/ }).click();
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-quick-menu").length >= 2);
      await page.locator(".acpmux-quick-menu").last().locator("[role=menuitemradio][aria-checked=true]").waitFor();
      // Measure the open menu, not its open motion (finite animations only).
      await page.evaluate(() =>
        Promise.all(
          document
            .getAnimations()
            .filter((animation) => Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)))
            .map((animation) => animation.finished.catch(() => undefined)),
        ),
      );
      const geometry = await page.evaluate(() => {
        const menus = document.querySelectorAll(".acpmux-quick-menu");
        const menu = menus[menus.length - 1]!;
        const rows = [...menu.querySelectorAll<HTMLElement>("[role=menuitemradio]")].map((row) => {
          const box = row.getBoundingClientRect();
          const label = row.querySelector(".acpmux-menu-label")!.getBoundingClientRect();
          const check = row.querySelector(".ui-menu-check")!.getBoundingClientRect();
          return {
            checked: row.getAttribute("aria-checked") === "true",
            inset: Math.round(label.left - box.left),
            checkFromEnd: Math.round(box.right - check.right),
            checkAfterLabel: check.left >= label.right,
          };
        });
        return { rows };
      });
      const chosen = geometry.rows.find((row) => row.checked)!;
      expect(chosen.checkAfterLabel, "the check sits after the label").toBe(true);
      expect(chosen.checkFromEnd, "the check sits at the row's trailing edge").toBeLessThanOrEqual(12);
      for (const row of geometry.rows) expect(row.inset, "no leading check gutter").toBeLessThanOrEqual(12);
      expect(new Set(geometry.rows.map((row) => row.inset)).size, "every label starts at the same x").toBe(1);
      await page.close();
    });
});
