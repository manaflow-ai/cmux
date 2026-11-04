// cmux-web-test-timeout: 600
// How the composer's menus open and close under the mouse (cg-composer item 2, click polish; Codex
// desktop is the reference): the + menu, the model button and the permission chip in the bar, and
// the folder chip on the location strip, in a chat's composer, a new chat's and the New Tab page's.
// The model button names the model and its effort. With a harness rail its menu shows the levels
// in the settings column; without one it keeps the Effort submenu.
//
// - Menus open on the press (pressRelease.ts). A second press on the same chip closes its menu.
// - With one menu open, a press on another chip opens that one at once: no press to dismiss first.
// - A press anywhere else only closes the menu: nothing under it is clicked (the mic does not start
//   dictation, the field takes no click), as a macOS menu swallows the click that dismisses it.
// - Escape closes the menu and puts the keyboard back on its chip, with the chip's focus ring.
// - Picking a permission mode hands the keyboard back to the prompt. A level in columns applies
//   while the menu stays open; Return closes it and returns to the prompt.
//
// Real Chromium and WebKit (the app's engine) with real pointer events, on the gallery stage at
// 760 and 300 px. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-menu-dismiss.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser });
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
  const visibleChip = (page: Page, selector: string) => page.locator(selector).filter({ visible: true }).first();
  const pressAt = async (page: Page, selector: string) => {
    const chip = visibleChip(page, selector);
    await chip.waitFor({ state: "visible" });
    const box = (await chip.boundingBox())!;
    await pressPoint(page, box.x + box.width / 2, box.y + box.height / 2);
  };
  /** Press a chip only once its centre is no longer covered by a closing or open popup. */
  const pressFreshChip = async (page: Page, selector: string) => {
    const chip = visibleChip(page, selector);
    await chip.waitFor({ state: "visible" });
    await page.waitForFunction(
      (selector) => {
        const button = [...document.querySelectorAll<HTMLElement>(selector)].find((candidate) => {
          const box = candidate.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
        });
        if (!button) return false;
        const box = button.getBoundingClientRect();
        const target = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
        return target === button || button.contains(target);
      },
      selector,
      { timeout: 5_000 },
    );
    const box = (await chip.boundingBox())!;
    // Let Playwright re-check the hit target immediately before dispatching the trusted pointer
    // sequence; a hover-induced layout adjustment between a sampled box and mouse.down otherwise
    // drops the click on a stale coordinate under load.
    await chip.click({ position: { x: box.width / 2, y: box.height / 2 } });
  };
  const pressPoint = async (page: Page, x: number, y: number) => {
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.up();
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
            const button = [...document.querySelectorAll<HTMLElement>(selector)].find((candidate) => {
              const box = candidate.getBoundingClientRect();
              return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
            });
            return button?.getAttribute("aria-expanded") === "true" || button?.hasAttribute("data-popup-open");
          })
          .map(([name]) => name),
      names.map((name) => [name, chip(name)] as const),
    );
  /** Waits for the requested menu state to be visible and interactive.
   *
   * A popup that is closing remains mounted while its opacity transition runs.  Waiting for every
   * animation in the document made this assertion depend on WebKit's animation bookkeeping under
   * load (and could include a stale, already non-interactive popup).  The state that matters for
   * the pointer checks is the live popup and its rendered geometry; closing popups are filtered
   * explicitly.
   */
  const settle = async (page: Page, names: string[], want: string[]) => {
    const pairs = names.map((name) => [name, chip(name)] as const);
    const settled = page.waitForFunction(
      ([pairs, want]) => {
        const open = pairs
          .filter(([, selector]) => {
            const button = [...document.querySelectorAll<HTMLElement>(selector)].find((candidate) => {
              const box = candidate.getBoundingClientRect();
              return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
            });
            return button?.getAttribute("aria-expanded") === "true" || button?.hasAttribute("data-popup-open");
          })
          .map(([name]) => name);
        if (open.join("\n") !== want.join("\n")) return false;
        const popups = [...document.querySelectorAll<HTMLElement>(".ui-popup")];
        const livePopups = popups.filter((popup) => !popup.hasAttribute("data-ending-style"));
        // A closing popup is visually gone at opacity 0, but it stays mounted with its hit target
        // until Base UI finishes the close transition.  Do not let the next press race that
        // transition: the state is settled only when an ending popup no longer intercepts input.
        if (
          popups.some(
            (popup) => popup.hasAttribute("data-ending-style") && getComputedStyle(popup).pointerEvents !== "none",
          )
        )
          return false;
        const popupFor = (button: HTMLElement) => {
          const rendered = (popup: HTMLElement) => {
            if (popup.hasAttribute("data-ending-style")) return false;
            const box = popup.getBoundingClientRect();
            const style = getComputedStyle(popup);
            return (
              box.width > 0 &&
              box.height > 0 &&
              style.visibility !== "hidden" &&
              style.display !== "none" &&
              Number.parseFloat(style.opacity) > 0 &&
              style.pointerEvents !== "none"
            );
          };
          const controls = button.getAttribute("aria-controls");
          const controlled = controls ? document.getElementById(controls) : null;
          const controlledPopup = controlled?.closest<HTMLElement>(".ui-popup");
          if (controlledPopup && rendered(controlledPopup)) return controlledPopup;
          return livePopups.find(
            (popup) =>
              rendered(popup) &&
              (popup.getAttribute("aria-label") === button.getAttribute("aria-label") ||
                (button.id && popup.getAttribute("aria-labelledby") === button.id)),
          );
        };
        // The trigger's expanded state and its own mounted live popup are the semantic contract.
        // Do not count generic popups: a stale unrelated surface can remain mounted while this
        // trigger's menu is closed.
        for (const name of want) {
          const button = [...document.querySelectorAll<HTMLElement>(pairs.find(([label]) => label === name)![1])].find(
            (candidate) => {
              const box = candidate.getBoundingClientRect();
              return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
            },
          );
          if (!button || !popupFor(button)) return false;
        }
        if (
          want.length === 0 &&
          pairs.some(([, selector]) => {
            const button = [...document.querySelectorAll<HTMLElement>(selector)].find((candidate) => {
              const box = candidate.getBoundingClientRect();
              return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
            });
            return button && popupFor(button);
          })
        )
          return false;
        return true;
      },
      [pairs, want] as const,
      { timeout: 5_000 },
    );
    const failure = await settled.then(
      () => undefined,
      (error: unknown) => error,
    );
    if (failure) {
      // Unsettled: say which chips are open, where the keyboard is and which popups are mounted,
      // which the timeout alone threw away, then fail as before.
      const seen = await page.evaluate(() => {
        const active = document.activeElement;
        return {
          focus: active?.closest("[aria-label]")?.getAttribute("aria-label") ?? active?.tagName,
          popups: [...document.querySelectorAll<HTMLElement>(".ui-popup")].map((popup) => {
            const state = popup.hasAttribute("data-ending-style") ? "ending" : "live";
            return [popup.getAttribute("aria-label"), state, getComputedStyle(popup).pointerEvents].join(" ");
          }),
        };
      });
      const open = await expanded(page, names);
      console.error(`settle: wanted [${want.join(", ")}], open [${open.join(", ")}]: ${JSON.stringify(seen)}`);
      throw failure;
    }
    return expanded(page, names);
  };
  /** Waits until the open menus have stopped moving, so a press lands where their rows rest. */
  const menusAtRest = (page: Page) =>
    page.waitForFunction(() =>
      [...document.querySelectorAll<HTMLElement>(".ui-popup:not([data-ending-style])")].every((popup) =>
        popup.getAnimations({ subtree: true }).every((animation) => animation.playState !== "running"),
      ),
    );
  /** Waits until `holds` is true in the page or 5 s pass; the expect after it reads the state. */
  const until = (page: Page, holds: (arg: string) => boolean, arg: string) =>
    page.waitForFunction(holds, arg, { timeout: 5_000 }).catch(() => {});
  /** Whether `name`'s chip is what the pointer would press at its centre (no open menu over it). */
  const onTop = (page: Page, name: string) =>
    page.evaluate((selector) => {
      const button = [...document.querySelectorAll<HTMLElement>(selector)].find((candidate) => {
        const box = candidate.getBoundingClientRect();
        return box.width > 0 && box.height > 0 && getComputedStyle(candidate).visibility !== "hidden";
      })!;
      const box = button.getBoundingClientRect();
      return document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)?.closest(selector) === button;
    }, chip(name));

  for (const [engine] of engines)
    for (const width of [760, 300])
      test(`${engine}: Folder and Environment switch on the same press at ${width} px`, async () => {
        const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
        try {
          await page.goto(stageURL("agent-pane.composer-context", "environment-picker", width));
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          const folder = 'button[aria-haspopup][aria-label="Folder"]';
          const environment = 'button[aria-haspopup][aria-label^="Environment:"]';
          // The fixture starts with Environment open. Each pointer press must both close
          // that popover and open its sibling, including at the narrow icon-only width.
          for (const [from, to] of [
            [environment, folder],
            [folder, environment],
          ] as const) {
            await page.locator(`${from}[aria-expanded="true"]`).waitFor();
            await pressAt(page, to);
            await page.locator(`${to}[aria-expanded="true"]`).waitFor();
            expect(await page.locator(from).getAttribute("aria-expanded")).toBe("false");
            // Closing may fade. The new trigger must be open before that old surface leaves.
            await page
              .locator(from === environment ? ".acpmux-env-popover" : ".acpmux-folder-popover:not(.acpmux-env-popover)")
              .waitFor({ state: "detached" });
            expect(await page.locator('.ui-popup input[role="combobox"]:visible').count()).toBe(1);
          }
        } finally {
          await page.close();
        }
      });

  for (const [engine] of engines)
    for (const width of [760, 300])
      for (const stage of STAGES) {
        const where = `${engine}: ${stage.entry} ${stage.variant} at ${width} px`;

        test(`${where}: a second press on a chip closes its menu`, async () => {
          const page = await open(engine, stage, width);
          for (const name of stage.chips) {
            await pressFreshChip(page, chip(name));
            expect({ name, open: await settle(page, stage.chips, [name]) }).toEqual({ name, open: [name] });
            await menusAtRest(page);
            await pressAt(page, chip(name));
            expect({ name, open: await settle(page, stage.chips, []) }).toEqual({ name, open: [] });
          }
          await page.close();
        });

        test(`${where}: with a menu open, one press on another chip opens that one`, async () => {
          const page = await open(engine, stage, width);
          for (const from of stage.chips)
            for (const to of stage.chips) {
              if (from === to) continue;
              await pressFreshChip(page, chip(from));
              expect({ from, open: await settle(page, stage.chips, [from]) }).toEqual({ from, open: [from] });
              await menusAtRest(page);
              // A menu that covers the other chip takes the press itself.
              if (await onTop(page, to)) {
                await pressAt(page, chip(to));
                expect({ from, to, open: await settle(page, stage.chips, [to]) }).toEqual({ from, to, open: [to] });
              }
              await page.keyboard.press("Escape");
              expect({ from, to, open: await settle(page, stage.chips, []) }).toEqual({ from, to, open: [] });
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
              await pressFreshChip(page, chip(name));
              expect({ name, open: await settle(page, stage.chips, [name]) }).toEqual({ name, open: [name] });
              await menusAtRest(page);
              const point = await clearPoint(page, target);
              if (!point) {
                await page.keyboard.press("Escape");
                expect({ name, open: await settle(page, stage.chips, []) }).toEqual({ name, open: [] });
                continue;
              }
              const before = await pressed();
              // The press's events are dispatched by the time it returns, so the counts below are final.
              await pressPoint(page, point.x, point.y);
              expect({ name, target, open: await settle(page, stage.chips, []) }).toEqual({ name, target, open: [] });
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
            await pressFreshChip(page, chip(name));
            await settle(page, stage.chips, [name]);
            await page.keyboard.press("Escape");
            await until(
              page,
              (selector) =>
                document.querySelectorAll(".ui-popup").length === 0 &&
                document.activeElement === document.querySelector(selector),
              chip(name),
            );
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

        test(`${where}: picking a mode or a level and closing hands the keyboard back to the prompt`, async () => {
          for (const name of stage.picks) {
            const page = await open(engine, stage, width);
            await pressFreshChip(page, chip(name));
            await settle(page, stage.chips, [name]);
            // Where the caller picks model and effort together (New Tab), the running model's effort
            // is a side dropdown beside its row (#27948): its effort item opens the levels.
            const sideEffort = ".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger";
            const sideLevel = '.acpmux-quick-effort-menu [role="menuitemradio"][aria-checked="false"]';
            const columnsLevel = '.acpmux-cols-tune [role="radio"][aria-checked="false"]:not([aria-disabled="true"])';
            if (name === "Model")
              await page
                .locator(`${columnsLevel}, ${sideEffort}, .acpmux-quick-sub:has-text("Effort")`)
                .first()
                .waitFor();
            if (name === "Model" && (await page.locator(".acpmux-cols").count()) > 0) {
              const level = page.locator(columnsLevel).first();
              const label = await level.locator(".acpmux-cols-name").textContent();
              await menusAtRest(page);
              await level.scrollIntoViewIfNeeded();
              await pressAt(page, columnsLevel);
              expect(await page.locator('.acpmux-cols-tune [role="radio"][aria-checked="true"]').textContent()).toBe(
                label,
              );
              expect(await settle(page, stage.chips, [name])).toEqual([name]);
              expect(
                await page.evaluate(() => document.activeElement?.matches('.acpmux-cols-search input[type="search"]')),
              ).toBe(true);
              await page.keyboard.press("Enter");
            } else if (name === "Model" && (await page.locator(sideEffort).count()) > 0) {
              // A submenu trigger opens on hover or from the keyboard (Base UI ignores a press while it
              // opens on hover): hover it, then press a level in its dropdown.
              await page.locator(sideEffort).first().hover();
              await page.locator(sideLevel).first().waitFor();
              await menusAtRest(page);
              await pressAt(page, sideLevel);
            } else if (name === "Model") {
              // The level rows sit in the model menu's Effort › submenu, the popup with no submenu row.
              await pressAt(page, '.acpmux-quick-sub:has-text("Effort")');
              await page.locator('[role="menu"]:not(:has(.acpmux-quick-sub)) [role="menuitemradio"]').first().waitFor();
              await menusAtRest(page);
              await pressAt(
                page,
                '[role="menu"]:not(:has(.acpmux-quick-sub)) [role="menuitemradio"][aria-checked="false"]',
              );
            } else await pressAt(page, '[role="menuitemradio"][aria-checked="false"]');
            await until(
              page,
              (field) =>
                document.querySelectorAll(".ui-popup").length === 0 && !!document.activeElement?.closest(field),
              stage.field,
            );
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
