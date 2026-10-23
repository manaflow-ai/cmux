// cmux-web-test-timeout: 300
// The quiet row's model button (Leo 2026-10-21, of #23742's capture: "WTF IS THIS UGLY BULLSHIT. WE
// ALREADY FIXED THE FONTS. THE BOLT DOESN'T GO THERE"), measured on the real composer in Chromium:
//   - Codex's running fast tier is a small bolt inside the model button, before the model's name, on
//     the text's line; no speed button sits in the box or the row;
//   - the button is quiet text: no edge, ring or fill at rest; the effort one step back of the name;
//     keyboard focus (a menu closed with Esc hands it back) draws the soft pill and a hairline, never
//     the bright ring the capture showed;
//   - the context ring sits on the row's grid: on the buttons' center line, its glyph after the effort
//     with no margin of its own (13 px with the 8 px pill inset of #24138), not 17;
//   - the button, its labels and the mode use the composer's own font, the prompt's (the app's UI
//     font), so a fallback can never come from the row itself;
//   - the row keeps "Opus 5.5  Medium" while it fits (a 410 px composer: live-qa read "Opus Med" with
//     about 250 px free) and shortens only when the row runs out, with nothing cut or overlapping.
//
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-model-quiet.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-model-quiet.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer model quiet", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer";
  const stageURL = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, {
      variant,
      frame: "component",
      width,
      theme: "Apple System Colors",
      colorScheme: "dark",
    })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  /** The stage `variant` at `width` px (the composer is 36 px narrower), settled, nothing focused. */
  const open = async (variant: string, width = 760): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 600 } });
    for (;;) {
      await page.goto(stageURL(variant, width));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await page.keyboard.press("Escape");
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };
  const BUTTON = ".acpmux-composer-foot .acpmux-model .acpmux-picker-button";

  test("Codex with Fast mode on: a small bolt inside the model button, before the name, on its line", async () => {
    const page = await open("reasoning-codex-fast");
    const drawn = await page.evaluate((selector) => {
      const button = document.querySelector<HTMLElement>(selector);
      const bolt = button?.querySelector<SVGElement>(".acpmux-model-bolt");
      const name = button?.querySelector<HTMLElement>(".acpmux-model-name");
      const box = (element: Element | null | undefined) => element?.getBoundingClientRect();
      return {
        speedButton: document.querySelectorAll(".acpmux-fast").length,
        boltsAnywhere: document.querySelectorAll(".acpmux-model-bolt").length,
        bolt: box(bolt) && {
          left: box(bolt)!.left,
          right: box(bolt)!.right,
          mid: (box(bolt)!.top + box(bolt)!.bottom) / 2,
          size: box(bolt)!.width,
        },
        name: box(name) && { left: box(name)!.left, mid: (box(name)!.top + box(name)!.bottom) / 2 },
        button: box(button) && { left: box(button)!.left, right: box(button)!.right },
        fill: bolt?.getAttribute("fill"),
      };
    }, BUTTON);
    await page.close();
    expect(drawn.speedButton, "no speed button in the box or the row").toBe(0);
    expect(drawn.boltsAnywhere, "one bolt, the model button's").toBe(1);
    expect(drawn.bolt, "the bolt is inside the model button").toBeDefined();
    expect(drawn.bolt!.left).toBeGreaterThanOrEqual(drawn.button!.left);
    expect(drawn.bolt!.right, "before the model's name").toBeLessThanOrEqual(drawn.name!.left + 0.5);
    expect(drawn.bolt!.size, "a small glyph").toBeLessThanOrEqual(13);
    expect(Math.abs(drawn.bolt!.mid - drawn.name!.mid), "on the name's line").toBeLessThanOrEqual(1);
    expect(drawn.fill, "an outline glyph").toBe("none");
  });

  for (const variant of ["reasoning-codex", "quiet-chips"])
    test(`${variant}: Fast mode off or Claude: no bolt anywhere`, async () => {
      const page = await open(variant);
      const bolts = await page.evaluate(() => document.querySelectorAll(".acpmux-fast, .acpmux-model-bolt").length);
      await page.close();
      expect(bolts).toBe(0);
    });

  const look = (page: Page) =>
    page
      .locator(BUTTON)
      .first()
      .evaluate((element) => {
        const clear = (color: string) => color === "transparent" || /rgba\(.*,\s*0\)$|\/\s*0\)$/.test(color);
        const alpha = (color: string) => {
          const slash = color.match(/\/\s*([\d.]+)\)$/);
          if (slash) return Number(slash[1]);
          const rgba = color.match(/rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/);
          return rgba ? Number(rgba[1]) : 1;
        };
        const style = getComputedStyle(element);
        return {
          filled: !clear(style.backgroundColor) || style.backgroundImage !== "none",
          border:
            style.borderTopStyle !== "none" && parseFloat(style.borderTopWidth) > 0 && !clear(style.borderTopColor),
          ring: (style.boxShadow.match(/(rgba?|color)\([^)]*\)/g) ?? []).some((color) => !clear(color)),
          outline: style.outlineStyle === "none" ? 0 : parseFloat(style.outlineWidth),
          outlineAlpha: style.outlineStyle === "none" ? 0 : alpha(style.outlineColor),
        };
      });
  /** A color's luminance-weighted ink, alpha included (over the dark stage, less is dimmer). */
  const ink = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => {
        const canvas = document.createElement("canvas").getContext("2d")!;
        canvas.fillStyle = "#000";
        canvas.fillRect(0, 0, 1, 1);
        canvas.fillStyle = getComputedStyle(element).color;
        canvas.fillRect(0, 0, 1, 1);
        const [r, g, b] = canvas.getImageData(0, 0, 1, 1).data;
        return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
      });

  test("the model button is quiet text: no edge at rest, the effort a step back, a hairline on keyboard focus", async () => {
    const page = await open("quiet-chips");
    const rest = await look(page);
    expect(rest, "no fill, border, ring or outline at rest").toEqual({
      filled: false,
      border: false,
      ring: false,
      outline: 0,
      outlineAlpha: 0,
    });
    const name = await ink(page, `${BUTTON} .acpmux-model-name`);
    const effort = await ink(page, `${BUTTON} .acpmux-model-detail:not(.acpmux-fit-label)`);
    expect(effort, "the effort sits one step back of the model's name").toBeLessThan(name - 8);

    // Keyboard focus, as a menu closed with Esc leaves it: the pill and a hairline, never a ring.
    await page.keyboard.press("Shift");
    await page.locator(BUTTON).first().focus();
    expect(
      await page
        .locator(BUTTON)
        .first()
        .evaluate((element) => element.matches(":focus-visible")),
    ).toBe(true);
    await eased(page);
    const focus = await look(page);
    await page.close();
    expect(focus.filled, "keyboard focus draws the soft pill").toBe(true);
    expect(focus.border || focus.ring, "no border or shadow ring").toBe(false);
    expect(focus.outline, "a hairline outline").toBeGreaterThan(0);
    expect(focus.outline, "a hairline outline").toBeLessThanOrEqual(1);
    expect(focus.outlineAlpha, "in the row's quiet ink").toBeLessThanOrEqual(0.3);
  });

  test("the context ring sits on the row's grid, its glyph after the effort with no margin of its own", async () => {
    const page = await open("quiet-chips");
    const grid = await page.evaluate((selector) => {
      const button = document.querySelector<HTMLElement>(selector)!;
      const effort = button.querySelector<HTMLElement>(".acpmux-model-detail:not(.acpmux-fit-label)")!;
      const ring = document.querySelector<HTMLElement>(".acpmux-composer-foot .acpmux-context-ring")!;
      const glyph = ring.querySelector("svg")!.getBoundingClientRect();
      const text = document.createRange();
      text.selectNodeContents(effort);
      const words = text.getBoundingClientRect();
      const box = button.getBoundingClientRect();
      const ringBox = ring.getBoundingClientRect();
      return {
        gap: glyph.left - words.right,
        centers: Math.abs((box.top + box.bottom) / 2 - (ringBox.top + ringBox.bottom) / 2),
      };
    }, BUTTON);
    await page.close();
    // The button's 8 px pill inset (#24138) and the ring's own 5 px, no margin on top (was 17 px).
    expect(grid.gap, "the ring's glyph follows the effort with no margin of its own").toBeLessThanOrEqual(14);
    expect(grid.gap, "and never touches it").toBeGreaterThanOrEqual(6);
    expect(grid.centers, "on the buttons' center line").toBeLessThanOrEqual(0.5);
  });

  test("the model button, its labels and the mode use the composer's font, the prompt's", async () => {
    const page = await open("quiet-chips");
    const fonts = await page.evaluate(() => {
      const family = (selector: string) => {
        const element = document.querySelector(selector);
        return element ? getComputedStyle(element).fontFamily : `missing ${selector}`;
      };
      return {
        composer: family(".acpmux-composer"),
        prompt: family(".acpmux-composer-box .acpmux-md"),
        button: family(".acpmux-composer-foot .acpmux-model .acpmux-picker-button"),
        name: family(".acpmux-composer-foot .acpmux-model-name"),
        effort: family(".acpmux-composer-foot .acpmux-model-detail"),
        mode: family(".acpmux-composer-foot .acpmux-access .acpmux-picker-button"),
      };
    });
    await page.close();
    // The app's UI font (SF Pro in the app's WebKit, styles.css `.acpmux-composer`).
    expect(fonts.composer).toBe("system-ui");
    for (const [part, family] of Object.entries(fonts)) expect(family, part).toBe(fonts.composer);
  });

  /** The forms the quiet row shows: each unit's visible label, and whether its controls fit. */
  const row = (page: Page) =>
    page.evaluate(() => {
      const foot = document.querySelector<HTMLElement>(".acpmux-composer-foot")!;
      const visible = (element: Element) => {
        const style = getComputedStyle(element);
        return style.position !== "absolute" && style.visibility !== "hidden" && style.display !== "none";
      };
      const label = (unit: string) =>
        [...foot.querySelectorAll<HTMLElement>(`[data-fit-part="${unit}"]`)]
          .filter(visible)
          .map((part) => part.dataset.label ?? part.textContent?.trim() ?? "")
          .join(" ");
      const boxes = [
        foot.querySelector(".acpmux-access .acpmux-picker-button"),
        foot.querySelector(".acpmux-model .acpmux-picker-button"),
        foot.querySelector(".acpmux-context-ring"),
      ]
        .filter((element): element is Element => element !== null)
        .map((element) => element.getBoundingClientRect());
      const edge = foot.getBoundingClientRect();
      const overlap = boxes.some((box, index) => index > 0 && box.left < boxes[index - 1]!.right - 0.5);
      const outside = boxes.some((box) => box.left < edge.left - 0.5 || box.right > edge.right + 0.5);
      const composer = document.querySelector<HTMLElement>(".acpmux-composer")!;
      const style = getComputedStyle(composer);
      return {
        composer: composer.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
        model: label("model"),
        effort: label("effort"),
        access: label("access"),
        steps: [...foot.attributes].filter((attribute) => attribute.name.startsWith("data-fit-")).map((a) => a.name),
        // What the model button shows: its visible text and drawn labels, in order.
        button: [...foot.querySelectorAll<HTMLElement>(".acpmux-model .acpmux-picker-button *")]
          .filter((element) => visible(element) && element.getBoundingClientRect().width > 0)
          .map(
            (element) =>
              [...element.childNodes]
                .filter((node) => node.nodeType === Node.TEXT_NODE)
                .map((node) => node.textContent)
                .join("") +
              (element.dataset.label && /^".+"$/.test(getComputedStyle(element, "::before").content)
                ? element.dataset.label
                : ""),
          )
          .join(" ")
          .replace(/\s+/g, " ")
          .trim(),
        overlap,
        outside,
        overflow: foot.scrollWidth > foot.clientWidth + 0.5,
      };
    });

  // Frame widths: the composer is 36 px narrower (410, 324, 264 px), and 204 and 164 px.
  for (const width of [446, 360, 300])
    test(`a ${width - 36} px composer keeps "Opus 5.5  Medium" and the mode's name: the row has room`, async () => {
      const page = await open("quiet-chips", width);
      const shown = await row(page);
      await page.close();
      expect(shown.composer).toBe(width - 36);
      expect({ model: shown.model, effort: shown.effort, steps: shown.steps }).toEqual({
        model: "Opus 5.5",
        effort: "Medium",
        steps: [],
      });
      expect(shown.access.length, "the mode keeps its name").toBeGreaterThan(2);
      expect(shown.button, "the model, then its effort, nothing between").toBe("Opus 5.5 Medium");
      expect([shown.overlap, shown.outside, shown.overflow]).toEqual([false, false, false]);
    });

  for (const width of [240, 200])
    test(`a ${width - 36} px composer shortens whole units, only as the row runs out, and nothing overlaps`, async () => {
      const page = await open("quiet-chips", width);
      const shown = await row(page);
      await page.close();
      expect(shown.steps.length, "a truly narrow row takes a step").toBeGreaterThan(0);
      expect(shown.effort === "Medium" && shown.model === "Opus 5.5", "something shortened").toBe(false);
      expect(shown.button, "no dot at any fit step").not.toMatch(/[•·\u2022\u00b7\u2219\u22c5]/);
      expect([shown.overlap, shown.outside, shown.overflow]).toEqual([false, false, false]);
    });
});
