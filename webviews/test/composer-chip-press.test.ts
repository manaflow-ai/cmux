// cmux-web-test-timeout: 300
// How a press on the composer's chips feels (cg-composer item 2, click polish; Codex desktop is the
// reference): the + menu, the model button (which names the model and its effort, Leo 2026-10-20:
// no effort chip of its own) and the permission chip in the bar, and the folder chip on the location
// strip, in a chat's composer, a new chat's and the New Tab page's.
//
// - The pointing hand over every chip, as over every clickable thing (desktop.css; Leo 2026-10-21:
//   "LOTS OF AREAS LIKE THAT SHOULD BE CHANGING MY CURSOR INDICATOR TO CLICKABLE").
// - A press shows its tone the moment the button goes down: the hover's ease does not delay it,
//   and the chip does not move: its layout box stays put, and it draws no shrink or dim (Leo
//   2026-10-19: no mousedown and mouseup click feedback).
// - A mouse click leaves no focus ring, on the chip or on the menu it opens, even right after
//   typing (WebKit draws a programmatic focus as keyboard focus once a key was pressed).
//   Keyboard focus on the same chip still shows: the soft hover pill, with no outline (#23745, Leo
//   2026-10-21: no focus rings in the agent pane).
// - Every chip takes a press over a box at least 24 px tall, the small folder chip included.
// - A menu row takes a press anywhere on it, its check gutter and trailing edge included.
//
// Real Chromium and WebKit (the app's engine) with real pointer events, on the gallery stage at
// 760 and 300 px. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-chip-press.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-chip-press.test.ts", async () => {
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
      console.warn(`composer-chip-press: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer chip press", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "picker-toggle" } });
    await warmGalleryFrame(vite, ["agent-pane.new-tab", "agent-pane.composer-pickers"], { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Stage = { entry: string; variant: string; field: string; chips: string[] };
  /** Each stage and the chips it shows, by accessible name. */
  const STAGES: Stage[] = [
    { entry: "agent-pane.composer", variant: "picker-toggle", field: ".acpmux-md", chips: ["Add", "Model", "Mode"] },
    { entry: "agent-pane.composer", variant: "new-chat-reasoning", field: ".acpmux-md", chips: ["Folder", "Model"] },
    {
      entry: "agent-pane.new-tab",
      variant: "reasoning-chip",
      field: ".nt-field",
      chips: ["Folder", "Model"],
    },
  ];
  const PILL_STAGE: Stage = {
    entry: "agent-pane.composer-pickers",
    variant: "pill-rail",
    field: ".acpmux-composer-gallery-shell",
    chips: ["Model", "Mode"],
  };
  const chip = (name: string) => `button[aria-haspopup][aria-label="${name}"]`;

  const open = async (engine: string, stage: (typeof STAGES)[number], width: number) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    for (const name of stage.chips) await page.locator(chip(name)).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };
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
  /** Resolves once the pointer is over the first element `selector` matches, or off it, as the page sees it. */
  const hovered = (page: Page, selector: string, over = true) =>
    page.waitForFunction(([selector, over]) => document.querySelector(selector)?.matches(":hover") === over, [
      selector,
      over,
    ] as const);
  /** A real press and release at the centre of `name`'s chip, once its menu has opened or closed and
   *  stopped easing. */
  const clickChip = async (page: Page, name: string) => {
    const locator = page.locator(chip(name)).first();
    const expanded = await locator.getAttribute("aria-expanded");
    const box = (await locator.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await page.waitForFunction(
      ([selector, expanded]) => document.querySelector(selector)?.getAttribute("aria-expanded") !== expanded,
      [chip(name), expanded] as const,
    );
    await eased(page);
  };
  /** The outlines drawn now: the focused element's, the chip's, and any open popup's. */
  const rings = (page: Page, name: string) =>
    page.evaluate((selector) => {
      const drawn = (element: Element | null) => {
        if (!element) return null;
        const style = getComputedStyle(element);
        return style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0;
      };
      const focused = document.activeElement;
      const popups = [...document.querySelectorAll(".ui-popup")].filter(drawn);
      return {
        focused: drawn(focused) ? `${focused!.tagName.toLowerCase()}.${String(focused!.className).split(" ")[0]}` : "",
        chip: drawn(document.querySelector(selector)),
        popups: popups.map((popup) => String(popup.className)),
      };
    }, chip(name));

  /** Whether the chip has keyboard focus and paints the soft pill: a tinted fill, or the pane's focus
   *  wash laid over it as a background image (shared/styles.css). */
  const pill = (page: Page, name: string) =>
    page.evaluate((selector) => {
      const button = document.querySelector(selector)!;
      const style = getComputedStyle(button);
      const clear = (color: string) => color === "transparent" || /^rgba\(0, 0, 0, 0\)$|\/ 0\)$/.test(color);
      const washes = [...style.backgroundImage.matchAll(/(?:rgba?|color)\([^()]*\)/g)].map(([color]) => color);
      return (
        button.matches(":focus-visible") && (!clear(style.backgroundColor) || washes.some((color) => !clear(color)))
      );
    }, chip(name));

  for (const [engine] of engines)
    for (const width of [760, 300])
      for (const stage of STAGES) {
        const where = `${engine}: ${stage.entry} ${stage.variant} at ${width} px`;

        test(`${where}: the pointing hand over every chip`, async () => {
          const page = await open(engine, stage, width);
          const cursors = await page.evaluate(
            (selectors) =>
              Object.fromEntries(
                selectors.map((selector) => [selector, getComputedStyle(document.querySelector(selector)!).cursor]),
              ),
            stage.chips.map(chip),
          );
          await page.close();
          expect(cursors).toEqual(Object.fromEntries(stage.chips.map((name) => [chip(name), "pointer"])));
        });

        test(`${where}: a press shows its tone at once, and the chip does not move`, async () => {
          const page = await open(engine, stage, width);
          for (const name of stage.chips) {
            const locator = page.locator(chip(name)).first();
            const read = () =>
              locator.evaluate((element) => {
                // The layout box (offset size, the drawn box's centre), and the drawn box's
                // transform and opacity, which a press leaves alone.
                const box = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                return {
                  background: style.backgroundColor,
                  transform: style.transform,
                  opacity: style.opacity,
                  centre: [box.x + box.width / 2, box.y + box.height / 2],
                  size: [(element as HTMLElement).offsetWidth, (element as HTMLElement).offsetHeight],
                };
              });
            const box = (await locator.boundingBox())!;
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            await hovered(page, chip(name));
            await eased(page);
            const hover = await read();
            await page.mouse.down();
            const pressed = await read();
            // Held: the tone the press settles to once nothing eases, which the first read must match.
            await eased(page);
            const held = await read();
            await page.mouse.up();
            await page.keyboard.press("Escape");
            await page.mouse.move(1, 1);
            await hovered(page, chip(name), false);
            await eased(page);
            // The chip never moves under a press, whatever tone it shows (#21986). A drawn centre can
            // land a subpixel off (a 51.5 px centre rounds either way), so a move is a whole pixel or more.
            const moved = (read: { centre: number[] }) =>
              Math.max(...read.centre.map((value, axis) => Math.abs(value - hover.centre[axis]!))) >= 1;
            expect({ name, size: pressed.size, moved: moved(pressed) }).toEqual({
              name,
              size: hover.size,
              moved: false,
            });
            expect({ name, size: held.size, moved: moved(held) }).toEqual({ name, size: hover.size, moved: false });
            // No shrink and no dim, pressed or held.
            for (const each of [hover, pressed, held])
              expect({ name, transform: each.transform, opacity: each.opacity }).toEqual({
                name,
                transform: "none",
                opacity: "1",
              });
            // Chromium leaves :active when focus moves into the model picker's search on the press;
            // the open chip keeps its wash. WebKit, the app's engine, holds it. A press that keeps the
            // hover tone (the quiet chips) has no separate pressed tone to compare.
            if (held.background === hover.background) continue;
            expect({ name, pressed: pressed.background }).toEqual({ name, pressed: held.background });
          }
          await page.close();
        });

        test(`${where}: a mouse click leaves no focus ring, after typing too; the keyboard shows the pill, ringless`, async () => {
          for (const name of stage.chips) {
            const page = await open(engine, stage, width);
            // Typing first: WebKit then draws a programmatic focus as keyboard focus.
            await page.locator(stage.field).first().click();
            await page.keyboard.type("hi");
            await clickChip(page, name);
            const opened = await rings(page, name);
            await clickChip(page, name);
            const closed = await rings(page, name);
            expect({ name, opened }).toEqual({ name, opened: { focused: "", chip: false, popups: [] } });
            expect({ name, closed: closed.chip }).toEqual({ name, closed: false });
            // Keyboard focus on the chip draws the soft pill and no ring (#23745).
            await page.keyboard.press("Escape");
            await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
            await page.keyboard.press("Shift");
            await page.locator(chip(name)).first().focus();
            const keyboard = { ring: (await rings(page, name)).chip, pill: await pill(page, name) };
            expect({ name, keyboard }).toEqual({ name, keyboard: { ring: false, pill: true } });
            await page.close();
          }
        });

        test(`${where}: every chip takes a press over a box at least 24 px tall`, async () => {
          const page = await open(engine, stage, width);
          const short = await page.evaluate(
            (selectors) =>
              selectors.flatMap((selector) => {
                const button = document.querySelector(selector)!;
                const box = button.getBoundingClientRect();
                const x = box.x + box.width / 2;
                const y = box.y + box.height / 2;
                return [y - 11.5, y + 11.5]
                  .filter((probe) => !document.elementFromPoint(x, probe)?.closest(selector))
                  .map((probe) => `${selector} misses y=${Math.round(probe - y)} (box ${Math.round(box.height)} px)`);
              }),
            stage.chips.map(chip),
          );
          await page.close();
          expect(short).toEqual([]);
        });
      }

  for (const [engine] of engines)
    test(`${engine}: a menu row takes a press anywhere on it, its check gutter and trailing edge included`, async () => {
      const misses: string[] = [];
      for (const stage of STAGES.slice(0, 2))
        for (const name of stage.chips) {
          const page = await open(engine, stage, 760);
          await clickChip(page, name);
          const rows = await page.evaluate(() =>
            [...document.querySelectorAll('[role^="menuitem"], [role="option"]')].map((row) => {
              const box = row.getBoundingClientRect();
              return {
                text: row.textContent?.trim().slice(0, 24) ?? "",
                x: box.x,
                y: box.y,
                w: box.width,
                h: box.height,
              };
            }),
          );
          for (const row of rows) {
            const probes = [
              [row.x + 1, row.y + row.h / 2],
              [row.x + row.w - 1, row.y + row.h / 2],
              [row.x + row.w / 2, row.y + 1],
              [row.x + row.w / 2, row.y + row.h - 1],
            ];
            const hits = await page.evaluate(
              (points) =>
                points.map(
                  ([x, y]) => !!document.elementFromPoint(x, y)?.closest('[role^="menuitem"], [role="option"]'),
                ),
              probes,
            );
            if (hits.includes(false)) misses.push(`${name} "${row.text}": ${hits.join(",")}`);
          }
          await page.close();
        }
      expect(misses).toEqual([]);
    });

  for (const [engine] of engines)
    test(`${engine}: the 400 px picker rail draws no pill at rest, and a pill on hover and while open`, async () => {
      const page = await open(engine, PILL_STAGE, 400);
      const state = (name: string) =>
        page
          .locator(chip(name))
          .first()
          .evaluate((element) => {
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return {
              background: style.backgroundColor,
              boxShadow: style.boxShadow,
              radius: parseFloat(style.borderTopLeftRadius),
              height: rect.height,
            };
          });
      const idle = await Promise.all(PILL_STAGE.chips.map(state));
      for (const [index, value] of idle.entries()) {
        // No pill at rest: the label and chevron only (Leo 2026-10-19, the Claude app's chips).
        expect(value.background, `${PILL_STAGE.chips[index]} draws no fill at rest`).toBe("rgba(0, 0, 0, 0)");
        expect(value.boxShadow, `${PILL_STAGE.chips[index]} draws no edge at rest`).toBe("none");
        expect(value.radius, `${PILL_STAGE.chips[index]} is pill-shaped`).toBeGreaterThanOrEqual(
          value.height / 2 - 0.5,
        );
        expect(value.height, `${PILL_STAGE.chips[index]} remains a usable target`).toBeGreaterThanOrEqual(24);
      }

      const model = page.locator(chip("Model")).first();
      const modelBox = (await model.boundingBox())!;
      await page.mouse.move(modelBox.x + modelBox.width / 2, modelBox.y + modelBox.height / 2);
      await hovered(page, chip("Model"));
      await eased(page);
      const hover = await state("Model");
      expect(hover.background, "hover draws the pill").not.toBe(idle[0]!.background);

      await model.click();
      await page.locator(".acpmux-quick-menu").first().waitFor();
      const openModel = await state("Model");
      expect(openModel.background, "open keeps the pill's hover step").not.toBe(idle[0]!.background);
      expect(openModel.boxShadow, "open draws no edge ring (Leo 2026-10-18)").toBe("none");
      await page.close();
    });
});
