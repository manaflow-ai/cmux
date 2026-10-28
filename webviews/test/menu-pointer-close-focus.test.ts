// cmux-web-test-timeout: 300
// A menu closed by the pointer (a press outside it, or a pick) leaves no focus ring behind: focus
// goes back where it was when the menu opened (the prompt), else onto the chip without a ring. A
// ring left on a chip after clicking away read as a stuck focus state (Leo 2026-10-18). Escape still
// puts the keyboard back on the chip with its ring.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/menu-pointer-close-focus.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("menu-pointer-close-focus.test.ts", async () => {
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
      console.warn(`menu pointer close focus: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("menu pointer close focus", () => test("browsers", () => {}));
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
    await installPaintedFrames(page);
    await page.goto(stageURL(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    return page;
  };
  /** Until no menu is still opening or closing (Base UI unmounts a closed menu, and moves focus,
   *  once its fade has finished) and two frames have painted after. */
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
  /** A real press and release at the centre of `selector`. */
  const press = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await settled(page);
  };

  /** The element that draws a focus ring now, if any (its class), and what has focus. */
  const ring = (page: Page) =>
    page.evaluate(() => {
      const ringed = [...document.querySelectorAll<HTMLElement>("button, [role=button], [tabindex]")].find(
        (element) => {
          const style = getComputedStyle(element);
          return style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0;
        },
      );
      return {
        ring: ringed ? String(ringed.className).split(" ").slice(0, 2).join(".") : "",
        focused: String(document.activeElement?.className ?? "").split(" ")[0] ?? "",
      };
    });

  for (const [engine] of engines) {
    for (const [name, selector, popup] of [
      // The model button's menu (Leo 2026-10-20: one model button; its menu holds Effort and Fast mode).
      ["Model", chip("Model"), ".ui-popup.ui-menu"],
      // The computer chip's searchable destination popover (#25316: a dialog with a search field).
      ["Computer", 'button[aria-label^="Computer"]', ".ui-popup.acpmux-location-menu"],
    ])
      test(`${engine}: ${name}: a press outside the open menu leaves no ring`, async () => {
        const page = await open(engine);
        // Nothing focused first, so the menu has nowhere to return but its chip.
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await press(page, selector!);
        await page.locator(popup!).first().waitFor();
        await page.mouse.click(750, 590);
        await page.locator(popup!).first().waitFor({ state: "detached" });
        await settled(page);
        expect((await ring(page)).ring).toBe("");
        await page.close();
      });

    test(`${engine}: a pick with the mouse hands focus back to the prompt, without a chip ring`, async () => {
      const page = await open(engine);
      await page.locator(".nt-field").click();
      await press(page, chip("Model"));
      await page.locator(".acpmux-quick-menu").first().waitFor();
      await press(page, ".acpmux-quick-menu [role=menuitemradio]:not([aria-checked=true]):not([data-disabled])");
      expect(await ring(page)).toEqual({ ring: "", focused: "nt-field" });
      await page.close();
    });

    test(`${engine}: one press on another chip opens its picker and keeps it, focus and all`, async () => {
      const page = await open(engine);
      await press(page, 'button[aria-label^="Computer"]');
      await page.locator(".ui-popup.acpmux-location-menu").first().waitFor();
      await press(page, chip("Model"));
      // The first popover's close lands after its fade; it must not pull focus back out of the picker.
      await page.locator(".ui-popup.acpmux-location-menu").first().waitFor({ state: "detached" });
      await settled(page);
      const state = await page.evaluate(() => ({
        expanded: [...document.querySelectorAll("button[aria-haspopup][aria-expanded=true]")].map((button) =>
          button.getAttribute("aria-label"),
        ),
        inPopup: !!document.activeElement?.closest(".acpmux-quick-menu"),
      }));
      expect(state).toEqual({ expanded: ["Model"], inPopup: true });
      await page.close();
    });

    test(`${engine}: Escape still puts the keyboard back on the chip, with its ring`, async () => {
      const page = await open(engine);
      await press(page, chip("Model"));
      await page.locator(".acpmux-quick-menu").first().waitFor();
      await page.keyboard.press("Escape");
      await page.locator(".acpmux-quick-menu").first().waitFor({ state: "detached" });
      await settled(page);
      const after = await page.evaluate(
        (selector) =>
          document.activeElement === document.querySelector(selector) &&
          document.activeElement!.matches(":focus-visible"),
        chip("Model"),
      );
      expect(after).toBe(true);
      await page.close();
    });
  }
});
