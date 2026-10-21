// cmux-web-test-timeout: 600
// How the composer's menus open and close under the mouse (cg-composer item 2, click polish; Codex
// desktop is the reference): the + menu, the model button and the permission chip in the bar, and
// the folder chip on the location strip, in a chat's composer, a new chat's and the New Tab page's.
// The model button names the model and its effort, and its menu holds the levels under Effort ›
// (Leo 2026-10-20: one button, no effort chip of its own).
//
// - Menus open on the press (pressRelease.ts). A second press on the same chip closes its menu.
// - With one menu open, a press on another chip opens that one at once: no press to dismiss first.
// - A press anywhere else only closes the menu: nothing under it is clicked (the mic does not start
//   dictation, the field takes no click), as a macOS menu swallows the click that dismisses it.
// - Escape closes the menu and puts the keyboard back on its chip, with the chip's focus ring.
// - Picking a permission mode, or a level in the model menu's Effort ›, hands the keyboard back to
//   the prompt.
//
// Real Chromium and WebKit (the app's engine) with real pointer events, on the gallery stage at
// 760 and 300 px. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-menu-dismiss.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-menu-dismiss.test.ts", async () => {
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
      console.warn(`composer-menu-dismiss: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer menu dismiss", () => test("browsers", () => {}));
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

  /** Each stage, the chips it shows by accessible name, and the ones whose pick returns to the prompt. */
  const STAGES = [
    {
      entry: "agent-pane.composer",
      variant: "picker-toggle",
      field: ".acpmux-md",
      chips: ["Add", "Model", "Mode"],
      picks: ["Mode"],
    },
    {
      entry: "agent-pane.composer",
      variant: "new-chat-reasoning",
      field: ".acpmux-md",
      chips: ["Folder", "Model"],
      picks: ["Model"],
    },
    {
      entry: "agent-pane.new-tab",
      variant: "reasoning-chip",
      field: ".nt-field",
      chips: ["Folder", "Model"],
      picks: ["Model"],
    },
  ];
  const chip = (name: string) => `button[aria-haspopup][aria-label="${name}"]`;

  const open = async (engine: string, stage: (typeof STAGES)[number], width: number) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    for (const name of stage.chips) await page.locator(chip(name)).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    // The prompt has the keyboard, as it does in the app.
    await page.locator(stage.field).first().click();
    return page;
  };
  /** A real press and release at the centre of `selector`'s box: whatever is on top there takes it. */
  const pressAt = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).first().boundingBox())!;
    await pressPoint(page, box.x + box.width / 2, box.y + box.height / 2);
  };
  const pressPoint = async (page: Page, x: number, y: number) => {
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.up();
    await page.waitForTimeout(300);
  };
  /** A point on `selector` that no open menu covers, from its trailing end, or null. */
  const clearPoint = (page: Page, selector: string) =>
    page.evaluate((selector) => {
      const target = document.querySelector(selector)!;
      const box = target.getBoundingClientRect();
      const y = box.y + box.height / 2;
      for (let x = box.right - 4; x > box.x; x -= 8)
        if (document.elementFromPoint(x, y)?.closest(selector) && target.contains(document.elementFromPoint(x, y)))
          return { x, y };
      return null;
    }, selector);
  /** The chips whose menu is open. */
  const expanded = (page: Page, names: string[]) =>
    page.evaluate(
      (pairs) =>
        pairs
          .filter(([, selector]) => {
            const button = document.querySelector(selector);
            return button?.getAttribute("aria-expanded") === "true" || button?.hasAttribute("data-popup-open");
          })
          .map(([name]) => name),
      names.map((name) => [name, chip(name)] as const),
    );
  /** Whether `name`'s chip is what the pointer would press at its centre (no open menu over it). */
  const onTop = (page: Page, name: string) =>
    page.evaluate((selector) => {
      const box = document.querySelector(selector)!.getBoundingClientRect();
      return !!document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)?.closest(selector);
    }, chip(name));

  for (const [engine] of engines)
    for (const width of [760, 300])
      for (const stage of STAGES) {
        const where = `${engine}: ${stage.entry} ${stage.variant} at ${width} px`;

        test(`${where}: a second press on a chip closes its menu`, async () => {
          const page = await open(engine, stage, width);
          for (const name of stage.chips) {
            await pressAt(page, chip(name));
            expect({ name, open: await expanded(page, stage.chips) }).toEqual({ name, open: [name] });
            await pressAt(page, chip(name));
            expect({ name, open: await expanded(page, stage.chips) }).toEqual({ name, open: [] });
          }
          await page.close();
        });

        test(`${where}: with a menu open, one press on another chip opens that one`, async () => {
          const page = await open(engine, stage, width);
          for (const from of stage.chips)
            for (const to of stage.chips) {
              if (from === to) continue;
              await pressAt(page, chip(from));
              // A menu that covers the other chip takes the press itself.
              if (await onTop(page, to)) {
                await pressAt(page, chip(to));
                expect({ from, to, open: await expanded(page, stage.chips) }).toEqual({ from, to, open: [to] });
              }
              await page.keyboard.press("Escape");
              await page.waitForTimeout(150);
            }
          await page.close();
        });

        test(`${where}: a press outside an open menu only closes it; nothing under it is clicked`, async () => {
          const page = await open(engine, stage, width);
          await page.evaluate((field) => {
            // Where the page's own handlers see a press: React's on its root, and the document.
            const counts = ((window as unknown as { pressed: Record<string, number> }).pressed = {});
            for (const type of ["pointerdown", "mousedown", "click"])
              document.addEventListener(type, (event) => {
                for (const [name, selector] of [
                  ["mic", ".acpmux-mic"],
                  ["field", field],
                ] as const)
                  if ((event.target as Element).closest?.(selector))
                    counts[`${name} ${type}`] = (counts[`${name} ${type}`] ?? 0) + 1;
              });
          }, stage.field);
          const pressed = () => page.evaluate(() => (window as unknown as { pressed: Record<string, number> }).pressed);
          for (const name of stage.chips)
            for (const target of [".acpmux-mic", stage.field]) {
              await pressAt(page, chip(name));
              expect({ name, open: await expanded(page, stage.chips) }).toEqual({ name, open: [name] });
              const point = await clearPoint(page, target);
              if (!point) {
                await page.keyboard.press("Escape");
                continue;
              }
              const before = await pressed();
              await pressPoint(page, point.x, point.y);
              expect({ name, target, open: await expanded(page, stage.chips) }).toEqual({ name, target, open: [] });
              expect({ name, target, pressed: await pressed() }).toEqual({ name, target, pressed: before });
              await page.keyboard.press("Escape");
            }
          // With no menu open, the same presses reach them.
          await pressAt(page, stage.field);
          expect((await pressed())["field click"]).toBe(1);
          await page.close();
        });

        test(`${where}: Escape closes a menu and puts the keyboard back on its chip`, async () => {
          for (const name of stage.chips) {
            const page = await open(engine, stage, width);
            await pressAt(page, chip(name));
            await page.keyboard.press("Escape");
            await page.waitForTimeout(250);
            const focus = await page.evaluate(
              (selector) => ({
                open: document.querySelectorAll(".ui-popup").length,
                onChip: document.activeElement === document.querySelector(selector),
                ring: document.activeElement?.matches(":focus-visible") ?? false,
              }),
              chip(name),
            );
            await page.close();
            expect({ name, focus }).toEqual({ name, focus: { open: 0, onChip: true, ring: true } });
          }
        });

        test(`${where}: picking a mode or a level hands the keyboard back to the prompt`, async () => {
          for (const name of stage.picks) {
            const page = await open(engine, stage, width);
            await pressAt(page, chip(name));
            if (name === "Model") {
              // The level rows sit in the model menu's Effort › submenu, the popup with no submenu row.
              await pressAt(page, '.acpmux-quick-sub:has-text("Effort")');
              await page.locator('[role="menu"]:not(:has(.acpmux-quick-sub)) [role="menuitemradio"]').first().waitFor();
              await pressAt(
                page,
                '[role="menu"]:not(:has(.acpmux-quick-sub)) [role="menuitemradio"][aria-checked="false"]',
              );
            } else await pressAt(page, '[role="menuitemradio"][aria-checked="false"]');
            const focus = await page.evaluate(
              (field) => ({
                open: document.querySelectorAll(".ui-popup").length,
                onPrompt: !!document.activeElement?.closest(field),
              }),
              stage.field,
            );
            await page.close();
            expect({ name, focus }).toEqual({ name, focus: { open: 0, onPrompt: true } });
          }
        });
      }
});
