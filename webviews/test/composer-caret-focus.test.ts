// cmux-web-test-timeout: 300
// One composer behavior everywhere (Leo 2026-10-19: "need to hide caret and deal with more focus
// stuff for composer"): the chat composer and the New Tab page's composer draw the same states.
//
// - Rest: each button is its icon or label, no pill. The button row is the chat's plain footer, so
//   the New Tab model chip drops the brand mark at a roomy width, as the chat's does.
// - Hover: the hovered button alone takes the soft pill (--acpmux-pill-hover), the mic included;
//   the composer box never changes under the pointer.
// - Keyboard focus: the same pill, with the bar's outline on its edge.
// - Caret and focus ring agree: the caret shows only while the composer shows its focused ring. A
//   field that holds DOM focus while the page is not the key one (the window or pane is in the
//   background, the New Tab page focused itself before the user came to it) hides its caret and
//   draws the resting ring; once the page is key again both come back together. Over art, the glass
//   card's focused rim follows the same rule.
//
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-caret-focus.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-caret-focus.test.ts", async () => {
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
      console.warn(`composer-caret-focus: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer caret and focus", () => test("browsers", () => {}));
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

  type Stage = { name: string; entry: string; variant: string; field: string; box: string; row: string };
  const COMPOSERS: Stage[] = [
    {
      name: "chat composer",
      entry: "agent-pane.composer",
      variant: "quiet-chips",
      field: ".acpmux-composer-box .acpmux-md",
      box: ".acpmux-composer-box",
      row: ".acpmux-composer-bar",
    },
    {
      name: "New Tab composer",
      entry: "agent-pane.new-tab",
      variant: "reasoning-chip",
      field: ".nt-field",
      box: ".nt-box",
      row: ".nt-pickers",
    },
  ];
  const CONTROLS = ":is(.acpmux-picker-button, .acpmux-mic, .acpmux-plan, .acpmux-steer, .acpmux-fast)";
  const TRANSPARENT = "rgba(0, 0, 0, 0)";

  const open = async (engine: string, stage: Stage, { rest = true } = {}) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    if (rest) {
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.mouse.move(1, 1);
      await page.waitForTimeout(250);
    }
    return page;
  };

  /** The page as the key window, or not: the field keeps DOM focus either way. */
  const setKey = (page: Page, key: boolean) =>
    page.evaluate((key) => {
      if (key) Reflect.deleteProperty(document, "hasFocus");
      else Object.defineProperty(document, "hasFocus", { configurable: true, value: () => false });
      window.dispatchEvent(new FocusEvent(key ? "focus" : "blur"));
    }, key);

  /** What the composer shows: its field's caret, its ring (the box and its rim layer), the focus. */
  const state = (page: Page, stage: Stage) =>
    page.evaluate(
      ({ field, box }) => {
        const input = document.querySelector<HTMLElement>(field)!;
        const card = document.querySelector<HTMLElement>(box)!;
        const caret = getComputedStyle(input).caretColor;
        return {
          focused: input.matches(":focus"),
          caret: caret !== "rgba(0, 0, 0, 0)" && caret !== "transparent",
          ring: `${getComputedStyle(card).boxShadow} | ${getComputedStyle(card, "::before").boxShadow}`,
        };
      },
      { field: stage.field, box: stage.box },
    );

  /** The soft pill as it resolves in this composer's button row. */
  const pillTone = (page: Page, stage: Stage) =>
    page.evaluate((row) => {
      const probe = document.createElement("div");
      probe.style.background = "var(--acpmux-pill-hover)";
      document.querySelector(row)!.append(probe);
      const tone = getComputedStyle(probe).backgroundColor;
      probe.remove();
      return tone;
    }, stage.row);

  const controls = (page: Page, stage: Stage) =>
    page.evaluate(
      ({ row, controls }) =>
        [...document.querySelectorAll<HTMLElement>(`${row} ${controls}`)]
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility === "visible";
          })
          .map((element, index) => ({
            index,
            label: element.getAttribute("aria-label") ?? element.className,
          })),
      { row: stage.row, controls: CONTROLS },
    );

  const look = (page: Page, stage: Stage, index: number) =>
    page.evaluate(
      ({ row, controls, index }) => {
        const element = [...document.querySelectorAll<HTMLElement>(`${row} ${controls}`)].filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && getComputedStyle(element).visibility === "visible";
        })[index]!;
        const style = getComputedStyle(element);
        return {
          background: style.backgroundColor,
          edge: style.boxShadow,
          outline: `${style.outlineStyle} ${style.outlineWidth}`,
          offset: style.outlineOffset,
        };
      },
      { row: stage.row, controls: CONTROLS, index },
    );

  for (const [engine] of engines) {
    // The New Tab row is the chat's footer: the same plain look, the model's brand mark hidden at a
    // roomy width and its name in the muted chip ink, as the chat's (composerLocation.css).
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: the button row is the plain footer, its model chip a muted label`, async () => {
        const page = await open(engine, stage);
        const row = await page.evaluate(
          ({ row }) => {
            const bar = document.querySelector<HTMLElement>(row)!;
            const mark = bar.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button .agent-mark");
            const model = bar.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button")!;
            const effort = bar.querySelector<HTMLElement>(".acpmux-effort .acpmux-picker-button");
            return {
              look: bar.dataset.footerLook ?? "",
              mark: mark ? getComputedStyle(mark).display : "none",
              muted: !effort || getComputedStyle(model).color === getComputedStyle(effort).color,
            };
          },
          { row: stage.row },
        );
        await page.close();
        expect(row).toEqual({ look: "plain", mark: "none", muted: true });
      });

    // Hover pills the one button under the pointer, every button the same soft pill (the mic too);
    // the box never answers the pointer.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: hover gives the hovered button alone the soft pill; the box stays put`, async () => {
        const page = await open(engine, stage);
        const fine = await page.evaluate(() => matchMedia("(hover: hover) and (pointer: fine)").matches);
        if (!fine) {
          await page.close();
          return;
        }
        const tone = await pillTone(page, stage);
        expect(tone, "the soft pill resolves").not.toBe(TRANSPARENT);
        const restBox = (await state(page, stage)).ring;
        const buttons = await controls(page, stage);
        expect(buttons.length, "the row shows its buttons").toBeGreaterThan(1);
        const wrong: string[] = [];
        for (const button of buttons) {
          const rest = await look(page, stage, button.index);
          if (rest.background !== TRANSPARENT || rest.edge !== "none") wrong.push(`${button.label}: a pill at rest`);
          const box = (await page.locator(`${stage.row} ${CONTROLS} >> visible=true`).nth(button.index).boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.waitForTimeout(300);
          const hovered = await look(page, stage, button.index);
          if (hovered.background !== tone) wrong.push(`${button.label}: hover ${hovered.background}, not ${tone}`);
          if (hovered.edge !== "none") wrong.push(`${button.label}: hover draws an edge`);
          for (const other of buttons)
            if (other.index !== button.index && (await look(page, stage, other.index)).background !== TRANSPARENT)
              wrong.push(`${button.label}: hover also pills ${other.label}`);
          if ((await state(page, stage)).ring !== restBox) wrong.push(`${button.label}: hover changes the box`);
          await page.mouse.move(1, 1);
          await page.waitForTimeout(300);
        }
        await page.close();
        expect(wrong).toEqual([]);
      });

    // Keyboard focus: the same soft pill and the bar's outline on the pill's edge, in both.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: keyboard focus gives a button the soft pill and the bar's outline`, async () => {
        const page = await open(engine, stage);
        const tone = await pillTone(page, stage);
        const wrong: string[] = [];
        for (const button of await controls(page, stage)) {
          // A key first, so a script focus counts as keyboard focus (:focus-visible) in both engines.
          await page.keyboard.press("Shift");
          await page.locator(`${stage.row} ${CONTROLS} >> visible=true`).nth(button.index).focus();
          await page.waitForTimeout(250);
          const focused = await look(page, stage, button.index);
          if (focused.background !== tone) wrong.push(`${button.label}: focus ${focused.background}, not ${tone}`);
          if (focused.edge !== "none") wrong.push(`${button.label}: focus draws an edge`);
          // The bar's outline, on the pill's edge (offset 0), never the shared ring 2 px off it.
          if (!focused.outline.startsWith("solid ") || focused.offset !== "0px")
            wrong.push(`${button.label}: outline ${focused.outline} at ${focused.offset}`);
          await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        }
        await page.close();
        expect(wrong).toEqual([]);
      });

    // The caret shows only with the focused ring; a field focused while the page is not the key one
    // shows neither, and both return together.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: the caret shows only while the focused ring does`, async () => {
        const page = await open(engine, stage);
        const rest = await state(page, stage);
        expect(rest.focused, "at rest the field has no focus").toBe(false);

        await page.locator(stage.field).first().click();
        await page.waitForTimeout(200);
        const engaged = await state(page, stage);
        expect(engaged.focused, "a click focuses the field").toBe(true);
        expect(engaged.caret, "the focused field shows its caret").toBe(true);
        expect(engaged.ring, "the focused field draws the focused ring").not.toBe(rest.ring);

        await setKey(page, false);
        await page.waitForTimeout(200);
        const background = await state(page, stage);
        expect(background.focused, "the field keeps DOM focus in the background").toBe(true);
        expect(background.caret, "in the background the caret hides").toBe(false);
        expect(background.ring, "in the background the box draws the resting ring").toBe(rest.ring);

        await setKey(page, true);
        await page.waitForTimeout(200);
        const back = await state(page, stage);
        expect(back.caret, "key again, the caret is back").toBe(true);
        expect(back.ring, "key again, the focused ring is back").toBe(engaged.ring);
        await page.close();
      });

    // A field that focused itself while the page was not key (New Tab's auto-focus, a spare page
    // adopted behind another window) shows no caret until the page is key; a key or a press on the
    // page means it is.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: a field focused while the page is in the background shows no caret`, async () => {
        const page = await open(engine, stage);
        const rest = (await state(page, stage)).ring;
        await setKey(page, false);
        await page.locator(stage.field).first().focus();
        await page.waitForTimeout(200);
        const background = await state(page, stage);
        expect(background).toEqual({ focused: true, caret: false, ring: rest });
        // A key typed on the page means it is the key one, whatever hasFocus() said.
        await page.keyboard.press("Shift");
        await page.waitForTimeout(200);
        const typed = await state(page, stage);
        expect(typed.caret, "a key brings the caret back").toBe(true);
        expect(typed.ring, "a key brings the focused ring back").not.toBe(rest);
        await setKey(page, false);
        await setKey(page, true);
        await page.waitForTimeout(200);
        const key = await state(page, stage);
        expect(key.caret, "key: the caret").toBe(true);
        expect(key.ring, "key: the focused ring").not.toBe(rest);
        await page.close();
      });

    // Opened as the key page, the composer's own focus (the New Tab page focuses its field) draws
    // caret and ring together, never one without the other.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: as it opens, caret and focused ring agree`, async () => {
        const page = await open(engine, stage, { rest: false });
        const opened = await state(page, stage);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await page.waitForTimeout(200);
        const rest = (await state(page, stage)).ring;
        await page.close();
        const ringShows = opened.ring !== rest;
        expect({ caret: opened.focused && opened.caret, ring: ringShows }).toEqual({
          caret: opened.focused,
          ring: opened.focused,
        });
      });

    // Over art the card is glass: focus brightens its top-lit rim in both composers, and only while
    // the page is key.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: over art focus brightens the glass rim, only while the page is key`, async () => {
        const page = await open(engine, stage);
        await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
        await page.waitForTimeout(100);
        const rim = () => page.evaluate((box) => getComputedStyle(document.querySelector(box)!).boxShadow, stage.box);
        const rest = await rim();
        await page.locator(stage.field).first().click();
        await page.waitForTimeout(200);
        const focused = await rim();
        await setKey(page, false);
        await page.waitForTimeout(200);
        const background = await rim();
        await page.close();
        expect(focused, "focus changes the glass card's rim").not.toBe(rest);
        // The top-lit rim (inset 0 1px 0) itself steps up, not only the ring.
        // WebKit and Chromium serialize the inset layer in their own orders.
        const topLit = (shadow: string) =>
          shadow.match(
            /(?:rgba?|color)\([^)]*\)\s*0px 1px 0px(?: 0px)?\s*inset|inset\s*0px 1px 0px(?: 0px)?\s*(?:rgba?|color)\([^)]*\)/,
          )?.[0];
        // Headless WebKit reports Reduce Transparency, so it draws no rim layer (composerStates.css);
        // there the ring alone shows focus.
        if (topLit(rest)) expect(topLit(focused), "the top-lit rim brightens").not.toBe(topLit(rest));
        expect(background, "in the background the glass rim rests").toBe(rest);
      });
  }
});
