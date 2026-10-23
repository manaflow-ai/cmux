// cmux-web-test-timeout: 300
// One composer behavior everywhere (Leo 2026-10-19: "need to hide caret and deal with more focus
// stuff for composer"): the chat composer and the New Tab page's composer draw the same states.
//
// - Rest: each button is its icon or label, no pill. The button row is the chat's plain footer, so
//   the New Tab model chip drops the brand mark at a roomy width, as the chat's does.
// - Hover: the hovered button alone takes the soft pill (--acpmux-pill-hover), the mic included;
//   the composer box never changes under the pointer.
// - Keyboard focus: the same pill, with the bar's outline on its edge.
// - Focus draws no ring (Leo 2026-10-19: the glass focus ring flashed): focused or not, the box
//   draws its resting ring, over art too; the caret alone shows focus. A field that holds DOM focus
//   while the page is not the key one (the window or pane is in the background, the New Tab page
//   focused itself before the user came to it) hides its caret; once the page is key it is back.
//
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-caret-focus.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Stage = {
    name: string;
    entry: string;
    variant: string;
    field: string;
    box: string;
    /** The composer's button rows: the box's own and the quiet row under it (ComposerFoot.tsx). */
    row: string;
    foot: string;
  };
  const COMPOSERS: Stage[] = [
    {
      name: "chat composer",
      entry: "agent-pane.composer",
      variant: "quiet-chips",
      field: ".acpmux-composer-box .acpmux-md",
      box: ".acpmux-composer-box",
      row: ".acpmux-composer-bar",
      foot: ".acpmux-composer .acpmux-composer-foot",
    },
    {
      name: "New Tab composer",
      entry: "agent-pane.new-tab",
      // Cards (composer-mic pins it), the first dot, whose box and quiet row these checks read.
      variant: "composer-mic",
      field: ".nt-field",
      box: ".nt-box",
      row: ":is(.nt-pickers, .acpmux-composer-foot)",
      foot: ".nt-composer .acpmux-composer-foot",
    },
    // Default, the second dot: its own composer (the chips, the mic and Send in the box), placed at
    // the foot of the stage layout's page.
    {
      name: "New Tab stage composer",
      entry: "agent-pane.new-tab",
      variant: "reasoning-chip-stage",
      field: ".nt-field",
      box: ".nt-box",
      row: ".nt-box .nt-pickers",
      foot: ".nt-box .nt-pickers",
    },
  ];
  const CONTROLS = ":is(.acpmux-picker-button, .acpmux-mic, .acpmux-plan)";
  const TRANSPARENT = "rgba(0, 0, 0, 0)";

  const open = async (engine: string, stage: Stage, { rest = true } = {}) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await page.goto(stageURL(stage.entry, stage.variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await installPaintedFrames(page);
    if (rest) {
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.mouse.move(1, 1);
      await settled(page);
    }
    return page;
  };

  /** Resolves once a frame has painted since the last input and every transition or animation that
   *  input started (a pill's fade, a ring's) has run out, so a read sees the look it comes to rest
   *  in. Endless animations (a spinner) never settle, so they are left out. */
  const settled = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      const finite = document
        .getAnimations()
        .filter((animation) => Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Infinity));
      await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
      await window.cmuxPaintFrame();
    });

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
          ({ foot }) => {
            const bar = document.querySelector<HTMLElement>(foot)!;
            const mark = bar.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button .agent-mark");
            const model = bar.querySelector<HTMLElement>(".acpmux-model .acpmux-picker-button")!;
            // The model button names its effort after the model (Leo 2026-10-20): the name is as
            // muted as that effort label, except in the quiet row under the box, where the name is in
            // the button's muted ink and the effort one step back of it (#24151: secondary ink).
            const name = model.querySelector<HTMLElement>(".acpmux-model-name") ?? model;
            const effort = model.querySelector<HTMLElement>(".acpmux-model-detail");
            const nameColor = getComputedStyle(name).color;
            const quietRow = bar.classList.contains("acpmux-composer-foot");
            return {
              look: bar.dataset.footerLook ?? "",
              mark: mark ? getComputedStyle(mark).display : "none",
              muted: !effort
                ? true
                : quietRow
                  ? nameColor === getComputedStyle(model).color && getComputedStyle(effort).color !== nameColor
                  : nameColor === getComputedStyle(effort).color,
            };
          },
          { foot: stage.foot },
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
          await settled(page);
          const hovered = await look(page, stage, button.index);
          if (hovered.background !== tone) wrong.push(`${button.label}: hover ${hovered.background}, not ${tone}`);
          if (hovered.edge !== "none") wrong.push(`${button.label}: hover draws an edge`);
          for (const other of buttons)
            if (other.index !== button.index && (await look(page, stage, other.index)).background !== TRANSPARENT)
              wrong.push(`${button.label}: hover also pills ${other.label}`);
          if ((await state(page, stage)).ring !== restBox) wrong.push(`${button.label}: hover changes the box`);
          await page.mouse.move(1, 1);
          await settled(page);
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
          await settled(page);
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

    // The caret shows only while the page is key; the ring never changes with focus.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: the caret shows only while the page is key, and focus draws no ring`, async () => {
        const page = await open(engine, stage);
        const rest = await state(page, stage);
        expect(rest.focused, "at rest the field has no focus").toBe(false);

        await page.locator(stage.field).first().click();
        await settled(page);
        const engaged = await state(page, stage);
        expect(engaged.focused, "a click focuses the field").toBe(true);
        expect(engaged.caret, "the focused field shows its caret").toBe(true);
        expect(engaged.ring, "the focused field draws the resting ring").toBe(rest.ring);

        await setKey(page, false);
        await settled(page);
        const background = await state(page, stage);
        expect(background.focused, "the field keeps DOM focus in the background").toBe(true);
        expect(background.caret, "in the background the caret hides").toBe(false);
        expect(background.ring, "in the background the box draws the resting ring").toBe(rest.ring);

        await setKey(page, true);
        await settled(page);
        const back = await state(page, stage);
        expect(back.caret, "key again, the caret is back").toBe(true);
        expect(back.ring, "key again, still the resting ring").toBe(rest.ring);
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
        await settled(page);
        const background = await state(page, stage);
        expect(background).toEqual({ focused: true, caret: false, ring: rest });
        // A key typed on the page means it is the key one, whatever hasFocus() said.
        await page.keyboard.press("Shift");
        await settled(page);
        const typed = await state(page, stage);
        expect(typed.caret, "a key brings the caret back").toBe(true);
        expect(typed.ring, "a key brings no ring").toBe(rest);
        await setKey(page, false);
        await setKey(page, true);
        await settled(page);
        const key = await state(page, stage);
        expect(key.caret, "key: the caret").toBe(true);
        expect(key.ring, "key: still the resting ring").toBe(rest);
        await page.close();
      });

    // Opened as the key page, the composer's own focus (the New Tab page focuses its field) shows the
    // caret and no ring: the box looks as it does at rest.
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: as it opens, a focused field shows its caret and no ring`, async () => {
        const page = await open(engine, stage, { rest: false });
        const opened = await state(page, stage);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await settled(page);
        const rest = (await state(page, stage)).ring;
        await page.close();
        expect({ caret: opened.focused && opened.caret, ring: opened.ring }).toEqual({
          caret: opened.focused,
          ring: rest,
        });
      });

    // Over art the card is glass: its top-lit rim rests whether the field is focused or not, and
    // whether the page is key or not (#22114's glass focus rim flashed, Leo 2026-10-19).
    for (const stage of COMPOSERS)
      test(`${engine}: ${stage.name}: over art focus leaves the glass rim at rest`, async () => {
        const page = await open(engine, stage);
        await page.evaluate(() => document.documentElement.setAttribute("data-cmux-see-through", ""));
        await settled(page);
        const rim = () => page.evaluate((box) => getComputedStyle(document.querySelector(box)!).boxShadow, stage.box);
        const rest = await rim();
        await page.locator(stage.field).first().click();
        await settled(page);
        const focused = await rim();
        await setKey(page, false);
        await settled(page);
        const background = await rim();
        await page.close();
        expect(focused, "focus leaves the glass card's rim and ring at rest").toBe(rest);
        expect(background, "in the background the glass rim rests").toBe(rest);
      });
  }
});
