// cmux-web-test-timeout: 300
// The composer's model button is plain text and icon at rest (Leo 2026-10-19: "✳ Opus 5.5 ⌄" and
// "Medium ⌄" showed a filled pill all the time). Since Leo 2026-10-20 it is one button that names the
// model and its effort ("Opus 5.5  Medium"); no effort chip of its own is drawn. The button draws a
// background only under the pointer, on keyboard focus or while its menu is open, and that
// background is the soft pill of the Claude app's chips (composer-chip-press.test.ts covers the
// press).
//
// It renders the real composer and New Tab box on the gallery stage in Chromium. CI fails the file
// when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-chip-plain-rest.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-chip-plain-rest.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer chip plain rest", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer", "agent-pane.new-tab"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing: no transition or animation left to run (a
   *  looping one never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (entry: string, variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 600 } });
    for (;;) {
      await page.goto(stageURL(entry, variant));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };
  const look = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => {
        const style = getComputedStyle(element);
        const clear = (color: string) => color === "transparent" || /rgba\(.*,\s*0\)$/.test(color);
        return {
          filled: !clear(style.backgroundColor) || style.backgroundImage !== "none",
          // A ring is any shadow layer in a visible color (a transparent inset is no ring).
          ring: (style.boxShadow.match(/rgba?\([^)]*\)/g) ?? []).some((color) => !clear(color)),
          radius: parseFloat(style.borderTopLeftRadius),
          height: element.getBoundingClientRect().height,
        };
      });

  const STAGES = [
    { entry: "agent-pane.composer", variant: "new-chat-reasoning" },
    { entry: "agent-pane.new-tab", variant: "reasoning-chip" },
  ];
  const CHIPS = [".acpmux-model .acpmux-picker-button"];

  for (const stage of STAGES)
    test(`${stage.entry} ${stage.variant}: the effort is the model button's label, not a chip of its own`, async () => {
      const page = await open(stage.entry, stage.variant);
      const drawn = await page.evaluate(() => ({
        chip: document.querySelectorAll(".acpmux-effort").length,
        detail: document.querySelectorAll(".acpmux-model .acpmux-picker-button .acpmux-model-detail").length,
      }));
      await page.close();
      expect(drawn.chip, "no effort chip").toBe(0);
      expect(drawn.detail, "the model button names its effort").toBeGreaterThan(0);
    });

  for (const stage of STAGES)
    for (const chip of CHIPS)
      test(`${stage.entry} ${stage.variant}: ${chip} is plain at rest; hover and focus draw the pill`, async () => {
        const page = await open(stage.entry, stage.variant);
        expect(await page.locator(chip).count(), "the stage shows the chip").toBeGreaterThan(0);
        const rest = await look(page, chip);
        expect({ filled: rest.filled, ring: rest.ring }, "plain at rest").toEqual({ filled: false, ring: false });

        // Keyboard focus draws the background (the chip's own :focus-visible). A key press first makes
        // the focus that follows keyboard focus, as Tab would.
        await page.keyboard.press("Shift");
        await page.locator(chip).first().focus();
        expect(
          await page
            .locator(chip)
            .first()
            .evaluate((element) => element.matches(":focus-visible")),
        ).toBe(true);
        const focus = await look(page, chip);
        expect(focus.filled, "keyboard focus draws a background").toBe(true);
        expect(focus.radius, "the pill shape").toBeGreaterThanOrEqual(focus.height / 2 - 0.5);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());

        const fine = await page.evaluate(() => matchMedia("(hover: hover) and (pointer: fine)").matches);
        if (fine) {
          const box = (await page.locator(chip).first().boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.waitForFunction((chip) => document.querySelector(chip)?.matches(":hover"), chip);
          await eased(page);
          const hover = await look(page, chip);
          expect(hover.filled, "hover draws a background").toBe(true);
          expect(hover.radius, "the pill shape").toBeGreaterThanOrEqual(hover.height / 2 - 0.5);
        }
        await page.close();
      });
});
