// cmux-web-test-timeout: 300
// The composer is quiet, like Claude's and ChatGPT's (Leo 2026-10-18): the box itself never answers
// the pointer, while the model button does, with one subtle step. The model button names the model
// and its effort and is the one control for both (Leo 2026-10-20: no effort chip, no speed bolt). A click on a pill
// holds that same step while its menu is open: no brighter press tone that flashes and no edge
// ring around the open pill.
//
// The New Tab page's pills (styles.css) and a new chat's pills in the composer bar
// (composerLocation.css) style the pill apart, so both are covered. Real Chromium and WebKit (the
// app's engine) on the gallery stage. CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-quiet-chips.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-quiet-chips.test.ts", async () => {
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
      console.warn(`composer-quiet-chips: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer quiet chips", () => test("browsers", () => {}));
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
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "reasoning-chip" } });
    await warmGalleryFrame(vite, ["agent-pane.composer", "agent-pane.composer-pickers"], { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  // The composer bar's buttons by their place: +, the model button and the mode chip.
  // (The pane's composer shows no Plan toggle, App.tsx showPlan={false}; the picker rail's gallery
  // stage below covers Plan.)
  const BAR = {
    plus: ".acpmux-composer-bar .acpmux-composer-plus .acpmux-picker-button",
    model: ".acpmux-composer-bar .acpmux-model .acpmux-picker-button",
    mode: ".acpmux-composer-bar .acpmux-access .acpmux-picker-button",
  };
  // A chip is named by its label, or by a selector (one that starts with ".").
  const STAGES = [
    { entry: "agent-pane.new-tab", variant: "reasoning-chip", chips: ["Model"] },
    // The Default template's stage layout: the same button in the footer under the box.
    { entry: "agent-pane.new-tab", variant: "reasoning-chip-stage", chips: ["Model"] },
    { entry: "agent-pane.composer", variant: "new-chat-reasoning", chips: ["Model"] },
    // Fast mode on (only in the model button's menu); + and the mode chip open menus.
    { entry: "agent-pane.composer", variant: "quiet-chips", chips: [BAR.plus, BAR.mode] },
  ];
  // Plan on (the picker rail's play turns it on): accent ink, no pill at rest.
  const REST_STAGES = [...STAGES, { entry: "agent-pane.composer-pickers", variant: "plan", chips: ["Model"] }];
  const CONTROLS = ":is(.acpmux-picker-button, .acpmux-mic, .acpmux-plan)";
  const chip = (name: string) => (name.startsWith(".") ? name : `button[aria-haspopup][aria-label="${name}"]`);

  const open = async (engine: string, entry: string, variant: string) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(stageURL(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // At rest: nothing focused, the pointer off the composer.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await page.waitForFunction((controls) => !document.querySelector(`${controls}:hover`), CONTROLS);
    await settle(page);
    return page;
  };
  /** Waits for a painted frame with the pointer's or focus's change and for every transition it
   *  started to end, so a read sees what the page holds, not a fade on its way there. */
  const settle = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      const transitions = document.getAnimations().filter((animation) => animation instanceof CSSTransition);
      await Promise.all(transitions.map((transition) => transition.finished.catch(() => {})));
      await window.cmuxPaintFrame();
    });
  /** Waits for the pointer to be over `selector`, then for the page to settle. */
  const hovered = async (page: Page, selector: string) => {
    await page.waitForFunction((selector) => document.querySelector(selector)?.matches(":hover"), selector);
    await settle(page);
  };
  const look = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((element) => {
        const style = getComputedStyle(element);
        return { background: `${style.backgroundColor} ${style.backgroundImage}`, edge: style.boxShadow };
      });
  // Every visible composer control: whether it draws a pill (a fill or an edge), and whether it is
  // the one under the pointer or keyboard focus.
  const pillsOf = (page: Page) =>
    page.evaluate((controls) => {
      return [...document.querySelectorAll<HTMLElement>(controls)]
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility === "visible";
        })
        .map((element) => {
          const style = getComputedStyle(element);
          const label = element.getAttribute("aria-label") ?? element.textContent?.trim() ?? element.className;
          const filled = style.backgroundColor !== "rgba(0, 0, 0, 0)" && style.backgroundColor !== "transparent";
          return {
            label,
            pill: filled || style.boxShadow !== "none",
            filled,
            edge: style.boxShadow,
            outline: style.outlineStyle,
            hovered: element.matches(":hover"),
            focused: element.matches(":focus-visible"),
          };
        });
    }, CONTROLS);

  for (const [engine] of engines) {
    test(`${engine}: the New Tab box looks the same under the pointer as at rest`, async () => {
      const page = await open(engine, "agent-pane.new-tab", "reasoning-chip");
      const rest = await look(page, ".nt-box");
      const box = (await page.locator(".nt-box").boundingBox())!;
      // Over the box's own empty area, clear of the field's text and every control.
      await page.mouse.move(box.x + box.width - 24, box.y + 10);
      await hovered(page, ".nt-box");
      expect(await look(page, ".nt-box")).toEqual(rest);
      await page.close();
    });

    for (const stage of STAGES)
      for (const name of stage.chips)
        test(`${engine}: ${stage.entry} ${stage.variant}: the ${name} pill steps on hover and holds it, ringless, through a click`, async () => {
          const page = await open(engine, stage.entry, stage.variant);
          const rest = await look(page, chip(name));
          const box = (await page.locator(chip(name)).first().boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await hovered(page, chip(name));
          const hover = await look(page, chip(name));
          // Hover lives under a fine pointer only; a headless engine may report a coarse one.
          const fine = await page.evaluate(() => matchMedia("(hover: hover) and (pointer: fine)").matches);
          if (fine) expect(hover.background, "hover steps the pill's fill").not.toBe(rest.background);
          await page.mouse.down();
          const pressed = await look(page, chip(name));
          await page.mouse.up();
          await page.waitForSelector(`${chip(name)}[aria-expanded="true"]`);
          await settle(page);
          const opened = await look(page, chip(name));
          expect(
            await page.locator(chip(name)).first().getAttribute("aria-expanded"),
            "the click opened its menu",
          ).toBe("true");
          expect(opened.edge, "no ring around the open pill").toBe("none");
          expect(opened.background, "the open pill keeps a fill").not.toBe(rest.background);
          expect(pressed, "no press flash: the press shows what the open pill holds").toEqual(opened);
          if (fine) expect(opened, "the open pill holds the hover step").toEqual(hover);
          await page.close();
        });

    // Leo 2026-10-19, against the Claude app's chips ("Bypass permissions"): at rest every control
    // shows its icon or label and no pill; the pointer gives a pill to the one button under it.
    for (const stage of REST_STAGES)
      test(`${engine}: ${stage.entry} ${stage.variant}: no control draws a pill at rest, and hover pills only the hovered one`, async () => {
        const page = await open(engine, stage.entry, stage.variant);
        const pills = () => pillsOf(page);
        const rest = await pills();
        expect(rest.length, "the stage shows its controls").toBeGreaterThan(1);
        expect(
          rest.filter((each) => each.pill),
          "no pill at rest",
        ).toEqual([]);
        const fine = await page.evaluate(() => matchMedia("(hover: hover) and (pointer: fine)").matches);
        if (fine) {
          const name = stage.chips[0]!;
          const box = (await page.locator(chip(name)).first().boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await hovered(page, chip(name));
          const pilled = await pills();
          const under = pilled.filter((each) => each.hovered).map((each) => each.label);
          expect(under.length, "the pointer is over one button").toBe(1);
          expect(
            pilled.filter((each) => each.pill).map((each) => each.label),
            "only the hovered button pills",
          ).toEqual(under);
        }
        await page.close();
      });

    // Keyboard focus gives the focused button the hover's pill, with no edge and no outline: every bar
    // button, + included (Leo 2026-10-19). The outline went with #23745 (Leo 2026-10-21: no focus
    // rings in the agent pane; the pill alone marks a focused button).
    test(`${engine}: keyboard focus pills the focused button only, ringless, with no outline`, async () => {
      const page = await open(engine, "agent-pane.composer", "quiet-chips");
      for (const [name, selector] of Object.entries(BAR)) {
        // A key first, so a script focus counts as keyboard focus (:focus-visible) in both engines.
        await page.keyboard.press("Shift");
        await page.locator(selector).first().focus();
        await settle(page);
        const controls = await pillsOf(page);
        const focused = controls.filter((each) => each.focused);
        expect(focused.length, `${name} has keyboard focus`).toBe(1);
        expect(focused[0]!.filled, `${name}: focus draws the pill`).toBe(true);
        expect(focused[0]!.edge, `${name}: no edge around the focused pill`).toBe("none");
        expect(focused[0]!.outline, `${name}: no focus outline`).toBe("none");
        expect(
          controls.filter((each) => each.pill && !each.focused).map((each) => each.label),
          `${name}: no other button pills`,
        ).toEqual([]);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      }
      await page.close();
    });

    // A press changes nothing (Leo 2026-10-19: no mousedown and mouseup click feedback): no shrink,
    // no dip and no spring back, and never a brighter or tinted tone (that part is the test above).
    // The chips that open a menu do it on pointerdown, so the press is read held and released too.
    const PRESSED = [
      { name: "New Tab model", entry: "agent-pane.new-tab", variant: "reasoning-chip", selector: chip("Model") },
      ...Object.entries(BAR).map(([name, selector]) => ({
        name,
        entry: "agent-pane.composer",
        variant: "quiet-chips",
        selector,
      })),
    ];
    for (const target of PRESSED)
      test(`${engine}: ${target.name}: a press neither shrinks nor dims the button, held or released`, async () => {
        const page = await open(engine, target.entry, target.variant);
        const button = page.locator(target.selector).first();
        const read = () =>
          button.evaluate((element) => {
            const style = getComputedStyle(element);
            const scale = style.transform === "none" ? 1 : new DOMMatrixReadOnly(style.transform).a;
            return { scale, opacity: Number(style.opacity) };
          });
        // Nothing to spring back: neither transform nor opacity is eased.
        const eased = await button.evaluate((element) => getComputedStyle(element).transitionProperty);
        const box = (await button.boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await hovered(page, target.selector);
        const hover = await read();
        await page.mouse.down();
        const pressed = await read();
        // Held: a chip whose menu opened on pointerdown has lost :active by now, but keeps
        // data-press-active (popoverTrigger.ts) until the release.
        await settle(page);
        const held = await read();
        await page.mouse.up();
        await settle(page);
        const after = await read();
        await page.close();
        expect(eased, "no transform to ease").not.toContain("transform");
        expect(eased, "no opacity to ease").not.toContain("opacity");
        expect(hover, "at hover the button is full size and opaque").toEqual({ scale: 1, opacity: 1 });
        expect(pressed, "mousedown changes nothing").toEqual(hover);
        expect(held, "held, nothing changes").toEqual(hover);
        expect(after, "mouseup changes nothing").toEqual(hover);
      });
  }
});
