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
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
    for (const [name, selector] of [
      ["Effort", chip("Effort")],
      ["Computer", 'button[aria-label^="Computer"]'],
    ])
      test(`${engine}: ${name}: a press outside the open menu leaves no ring`, async () => {
        const page = await open(engine);
        // Nothing focused first, so the menu has nowhere to return but its chip.
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await press(page, selector!);
        await page.locator(".ui-popup.ui-menu").first().waitFor();
        await page.mouse.click(750, 590);
        await page.waitForTimeout(400);
        expect((await ring(page)).ring).toBe("");
        await page.close();
      });

    test(`${engine}: a pick with the mouse hands focus back to the prompt, without a chip ring`, async () => {
      const page = await open(engine);
      await page.locator(".nt-field").click();
      await press(page, chip("Effort"));
      await press(page, ".acpmux-effort-menu [role=menuitemradio]:not([aria-checked=true])");
      expect(await ring(page)).toEqual({ ring: "", focused: "nt-field" });
      await page.close();
    });

    test(`${engine}: Escape still puts the keyboard back on the chip, with its ring`, async () => {
      const page = await open(engine);
      await press(page, chip("Effort"));
      await page.locator(".acpmux-effort-menu").waitFor();
      await page.keyboard.press("Escape");
      await page.waitForTimeout(300);
      const after = await page.evaluate(
        (selector) =>
          document.activeElement === document.querySelector(selector) &&
          document.activeElement!.matches(":focus-visible"),
        chip("Effort"),
      );
      expect(after).toBe(true);
      await page.close();
    });
  }
});
