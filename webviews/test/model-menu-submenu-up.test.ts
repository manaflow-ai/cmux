// cmux-web-test-timeout: 300
// Leo 2026-10-21 on the nightly: "this effort should open up top instead of bottom i think". The
// composer sits at the foot of the window, so its model menu opens up from the model button; its
// Effort submenu opened down from its row, toward the window's edge. A submenu now grows toward the
// room its row has: up from the row's bottom here, as Claude Code's does, and down from its top for
// a menu near the top of the window. Base UI still flips it when that side has no room.
// Here the running model's effort is a side dropdown beside its row (#27948), the same room-aware
// Submenu (ui/Menu.tsx) as the Effort row a menu without one keeps.
// Real Chromium and WebKit (the app's engine) on the gallery stage, the composer pinned to the
// bottom (or the top) of the viewport. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/model-menu-submenu-up.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-menu-submenu-up.test.ts", async () => {
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
      console.warn(`model menu submenu: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("model menu submenu", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "agent-pane.composer-pickers";
  const VARIANT = "closed";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: VARIANT, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

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

  /** The stage with its composer pinned to the viewport's bottom (or top) edge. */
  const open = async (engine: string, edge: "bottom" | "top"): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 640 } });
    await page.goto(stageURL());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await page.addStyleTag({
      content: `.acpmux-composer-gallery-shell { position: fixed !important; inset-inline: 12px !important; ${edge}: 8px !important; }`,
    });
    await installPaintedFrames(page);
    return page;
  };
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

  /** Opens the model menu and the running model's effort dropdown (else its Effort submenu); the row's and the submenu's boxes, and the viewport's height. */
  const submenuBoxes = async (page: Page) => {
    const button = page.locator('button[aria-haspopup][aria-label="Model"]').first();
    const box = (await button.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await page.locator('.acpmux-quick-menu [role="menuitemradio"]').first().waitFor();
    await atRest(page);
    // The running model's effort item opens its side dropdown (#27948); a menu without one keeps
    // its Effort row.
    const side = page.locator(".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger").first();
    const row = (await side.count())
      ? side
      : page.locator('.acpmux-quick-menu [role="menuitem"]', { hasText: /^Effort/ }).first();
    await row.focus();
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-quick-menu").length > 1);
    await atRest(page);
    return page.evaluate(() => {
      const rect = (element: Element | null | undefined) => {
        const box = element!.getBoundingClientRect();
        return { top: box.top, bottom: box.bottom };
      };
      const menus = [...document.querySelectorAll(".acpmux-quick-menu")];
      const row =
        menus[0]!.querySelector(".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger") ??
        [...menus[0]!.querySelectorAll('[role="menuitem"]')].find((item) =>
          item.textContent?.trim().startsWith("Effort"),
        );
      return {
        button: rect(document.querySelector('button[aria-label="Model"]')),
        menu: rect(menus[0]),
        row: rect(row),
        sub: rect(menus.at(-1)),
        height: window.innerHeight,
      };
    });
  };

  for (const [engine] of engines) {
    test(`${engine}: at the window's foot, a submenu opens up from its row`, async () => {
      const page = await open(engine, "bottom");
      const boxes = await submenuBoxes(page);
      expect(boxes.menu.bottom, "the menu opens above the model button").toBeLessThanOrEqual(boxes.button.top + 1);
      expect(boxes.sub.top, "the submenu's top is above its row").toBeLessThan(boxes.row.top - 1);
      expect(Math.abs(boxes.sub.bottom - boxes.row.bottom), "its bottom meets its row's").toBeLessThanOrEqual(12);
      expect(boxes.sub.bottom, "inside the window").toBeLessThanOrEqual(boxes.height);
      expect(boxes.sub.top, "inside the window").toBeGreaterThanOrEqual(0);
      await page.close();
    });

    test(`${engine}: at the window's top, a submenu opens down from its row`, async () => {
      const page = await open(engine, "top");
      const boxes = await submenuBoxes(page);
      expect(boxes.menu.top, "the menu opens below the model button").toBeGreaterThanOrEqual(boxes.button.bottom - 1);
      expect(Math.abs(boxes.sub.top - boxes.row.top), "its top meets its row's").toBeLessThanOrEqual(12);
      expect(boxes.sub.bottom, "inside the window").toBeLessThanOrEqual(boxes.height);
      await page.close();
    });
  }
});
