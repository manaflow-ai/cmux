// cmux-web-test-timeout: 300
// How a press on the composer's chips feels (cg-composer item 2, click polish; Codex desktop is the
// reference): the + menu, model, reasoning and permission chips in the bar, and the folder chip on
// the location strip, in a chat's composer, a new chat's and the New Tab page's.
//
// - The arrow cursor over every chip, as the rest of the pane's controls (macOS), never the hand.
// - A press shows its tone the moment the button goes down: the hover's ease does not delay it,
//   and the chip does not move: its layout box stays put, and the press's small shrink
//   (composerStates.css, the Claude app's chips) draws around the same centre.
// - A mouse click leaves no focus ring, on the chip or on the menu it opens, even right after
//   typing (WebKit draws a programmatic focus as keyboard focus once a key was pressed).
//   Keyboard focus on the same chip still shows its ring.
// - Every chip takes a press over a box at least 24 px tall, the small folder chip included.
// - A menu row takes a press anywhere on it, its check gutter and trailing edge included.
//
// Real Chromium and WebKit (the app's engine) with real pointer events, on the gallery stage at
// 760 and 300 px. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-chip-press.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}&frame=component&width=${width}&theme=Catppuccin+Mocha`;

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
      await warm.goto(stageURL("agent-pane.composer", "picker-toggle", 760));
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

  type Stage = { entry: string; variant: string; field: string; chips: string[] };
  /** Each stage and the chips it shows, by accessible name. */
  const STAGES: Stage[] = [
    { entry: "agent-pane.composer", variant: "picker-toggle", field: ".acpmux-md", chips: ["Add", "Model", "Mode"] },
    { entry: "agent-pane.composer", variant: "new-chat-reasoning", field: ".acpmux-md", chips: ["Folder", "Effort"] },
    {
      entry: "agent-pane.new-tab",
      variant: "reasoning-chip",
      field: ".nt-field",
      chips: ["Folder", "Model", "Effort"],
    },
  ];
  const PILL_STAGE: Stage = {
    entry: "agent-pane.composer-pickers",
    variant: "pill-rail",
    field: ".acpmux-composer-gallery-shell",
    chips: ["Model", "Effort", "Mode"],
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
  /** A real press and release at the centre of `name`'s chip. */
  const clickChip = async (page: Page, name: string) => {
    const box = (await page.locator(chip(name)).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await page.waitForTimeout(250);
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

  for (const [engine] of engines)
    for (const width of [760, 300])
      for (const stage of STAGES) {
        const where = `${engine}: ${stage.entry} ${stage.variant} at ${width} px`;

        test(`${where}: the arrow cursor over every chip`, async () => {
          const page = await open(engine, stage, width);
          const cursors = await page.evaluate(
            (selectors) =>
              Object.fromEntries(
                selectors.map((selector) => [selector, getComputedStyle(document.querySelector(selector)!).cursor]),
              ),
            stage.chips.map(chip),
          );
          await page.close();
          expect(cursors).toEqual(Object.fromEntries(stage.chips.map((name) => [chip(name), "default"])));
        });

        test(`${where}: a press shows its tone at once, and the chip does not move`, async () => {
          const page = await open(engine, stage, width);
          for (const name of stage.chips) {
            const locator = page.locator(chip(name)).first();
            const read = () =>
              locator.evaluate((element) => {
                // The layout box (offset size, the drawn box's centre): a press's shrink is a
                // transform, which scales the drawn box around its centre and moves nothing.
                const box = element.getBoundingClientRect();
                return {
                  background: getComputedStyle(element).backgroundColor,
                  centre: [box.x + box.width / 2, box.y + box.height / 2],
                  size: [(element as HTMLElement).offsetWidth, (element as HTMLElement).offsetHeight],
                };
              });
            const box = (await locator.boundingBox())!;
            await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
            await page.waitForTimeout(200);
            const hover = await read();
            await page.mouse.down();
            const pressed = await read();
            await page.waitForTimeout(200);
            const held = await read();
            await page.mouse.up();
            await page.keyboard.press("Escape");
            await page.mouse.move(1, 1);
            await page.waitForTimeout(200);
            // The chip never moves under a press, whatever tone it shows (#21986). The shrink's drawn
            // centre can land a subpixel off the unscaled one (a 51.5 px centre rounds either way),
            // so a move is a whole pixel or more.
            const moved = (read: { centre: number[] }) =>
              Math.max(...read.centre.map((value, axis) => Math.abs(value - hover.centre[axis]!))) >= 1;
            expect({ name, size: pressed.size, moved: moved(pressed) }).toEqual({
              name,
              size: hover.size,
              moved: false,
            });
            expect({ name, size: held.size, moved: moved(held) }).toEqual({ name, size: hover.size, moved: false });
            // Chromium leaves :active when focus moves into the model picker's search on the press;
            // the open chip keeps its wash. WebKit, the app's engine, holds it. A press that keeps the
            // hover tone (the quiet chips) has no separate pressed tone to compare.
            if (held.background === hover.background) continue;
            expect({ name, pressed: pressed.background }).toEqual({ name, pressed: held.background });
          }
          await page.close();
        });

        test(`${where}: a mouse click leaves no focus ring, after typing too; the keyboard still shows one`, async () => {
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
            // Keyboard focus on the chip draws its ring.
            await page.keyboard.press("Escape");
            await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
            await page.keyboard.press("Shift");
            await page.locator(chip(name)).first().focus();
            expect({ name, keyboard: (await rings(page, name)).chip }).toEqual({ name, keyboard: true });
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
      await page.waitForTimeout(100);
      const hover = await state("Model");
      expect(hover.background, "hover draws the pill").not.toBe(idle[0]!.background);

      await page.locator(chip("Effort")).first().click();
      await page.locator('[role="menuitemradio"][aria-checked="true"]:visible').first().waitFor();
      const openEffort = await state("Effort");
      expect(openEffort.background, "open keeps the pill's hover step").not.toBe(idle[1]!.background);
      expect(openEffort.boxShadow, "open draws no edge ring (Leo 2026-10-18)").toBe("none");
      await page.close();
    });
});
