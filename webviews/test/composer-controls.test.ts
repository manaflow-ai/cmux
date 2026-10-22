// cmux-web-test-timeout: 600
// One set of metrics for every composer control (Leo 2026-10-21: "did we have a generalized
// solution to the weird pills? that you added to the bottom?"; Lawrence's notes on the composer:
// "there's too many buttons here", "left/top/bottom padding", "weird padding", "weird padding").
// Every control in the composer is a ComposerControl (ComposerControl.tsx): a chip (the mode, the
// model button, the harness) or an icon button (+, the mic, Send, Stop, ↵, the context ring), drawn
// from one set of tokens (composerLocation.css, `--composer-control-*`). On the gallery stage, in Chromium and WebKit:
//   - every control is one height; every chip has the same padding on both sides and the same
//     icon-text gap; every icon button is square; all share one corner radius and the hand cursor;
//   - at rest no control draws a fill; hovered, each draws the same one;
//   - the + sits the same distance from the box's left, top and bottom edges;
//   - while a turn runs, exactly one of Stop and Send (or ↵) shows: Stop with an empty prompt,
//     Send or ↵ once there is text; the running tray's row keeps its own □ off until it is hovered,
//     so the composer's Stop is the one Stop at rest;
//   - no control draws a "•" (the model button's update dot read as one).
//
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-controls.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-controls.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-controls: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer controls", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;
  const STAGES: [string, string][] = [
    ["agent-pane.composer", "quiet-chips"],
    ["agent-pane.composer", "draft"],
    ["agent-pane.composer", "working"],
    ["agent-pane.composer", "working-steer"],
    ["agent-pane.composer", "working-queue"],
    ["agent-pane.subagent-tray", "one-running"],
    ["agent-pane.model-picker", "update-offer"],
  ];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    // One load per entry warms its modules; its other variants reuse them.
    const warmed = new Set<string>();
    for (const [entry, variant] of STAGES) {
      if (warmed.has(entry)) continue;
      warmed.add(entry);
      await warmGalleryFrame(vite, entry, { browser, params: { variant }, timeoutMs: 200_000 });
    }
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(engine: string, entry: string, variant: string, width = 760): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 520 } });
    await page.goto(stageURL(entry, variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    await rest(page);
    return page;
  }

  /** Two frames for a hover or focus change to apply, then until no CSS transition still runs. */
  async function settle(page: Page) {
    await page.evaluate(
      () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))),
    );
    await page.waitForFunction(
      () =>
        !document
          .getAnimations()
          .some((animation) => animation instanceof CSSTransition && animation.playState === "running"),
    );
  }

  /** Nothing hovered or focused: the pointer in the page's corner, focus on the body. */
  async function rest(page: Page) {
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await settle(page);
  }

  /** The composer's controls, by what they are, with their box, metrics and resting fill. */
  const CONTROLS = {
    plus: ".acpmux-composer-box .acpmux-composer-plus .acpmux-picker-button",
    mic: ".acpmux-composer-box .acpmux-mic",
    send: ".acpmux-composer-box .acpmux-send",
    mode: ".acpmux-composer-foot .acpmux-access .acpmux-picker-button",
    model: ".acpmux-composer-foot .acpmux-model .acpmux-picker-button",
    harness: ".acpmux-composer-foot .acpmux-harness .acpmux-picker-button",
    ring: ".acpmux-composer-foot .acpmux-context-ring",
  } as const;
  type Metrics = {
    name: string;
    control: string | null;
    height: number;
    width: number;
    paddingLeft: number;
    paddingRight: number;
    gap: string;
    radius: string;
    cursor: string;
    background: string;
    disabled: boolean;
  };
  const measure = (page: Page) =>
    page.evaluate((controls) => {
      const found: Metrics[] = [];
      for (const [name, selector] of Object.entries(controls))
        for (const element of document.querySelectorAll<HTMLElement>(selector)) {
          const box = element.getBoundingClientRect();
          if (box.width === 0 || box.height === 0) continue;
          const style = getComputedStyle(element);
          found.push({
            name,
            control: element.getAttribute("data-control"),
            height: box.height,
            width: box.width,
            paddingLeft: parseFloat(style.paddingLeft),
            paddingRight: parseFloat(style.paddingRight),
            gap: style.columnGap,
            radius: style.borderTopLeftRadius,
            cursor: style.cursor,
            background: style.backgroundColor,
            disabled: (element as HTMLButtonElement).disabled === true,
          });
        }
      return found;
    }, CONTROLS) as Promise<Metrics[]>;
  const clear = (color: string) => color === "transparent" || /rgba\([^)]*,\s*0\)$/.test(color);

  for (const [engine] of engines) {
    test(`${engine}: every composer control shares one height, padding, gap, radius and cursor, with no fill at rest`, async () => {
      const page = await open(engine, "agent-pane.composer", "quiet-chips");
      // A typed prompt brings Send in beside the mic.
      await page.click(".acpmux-composer-box .acpmux-md");
      await page.keyboard.type("jlkj");
      await rest(page);
      const all = await measure(page);
      const names = new Set(all.map((control) => control.name));
      for (const name of ["plus", "mic", "send", "mode", "model", "ring"]) expect(names).toContain(name);
      // Each is a ComposerControl, a chip or an icon button.
      for (const control of all)
        expect([control.name, control.control]).toEqual([control.name, expect.stringMatching(/^(chip|icon)$/)]);
      const chips = all.filter((control) => control.control === "chip");
      const icons = all.filter((control) => control.control === "icon");
      expect(chips.map((control) => control.name).sort()).toEqual(
        all
          .filter((control) => ["mode", "model", "harness"].includes(control.name))
          .map((c) => c.name)
          .sort(),
      );
      // One height.
      const height = all[0]!.height;
      for (const control of all) expect([control.name, control.height]).toEqual([control.name, height]);
      // Chips: one padding, the same on both sides; one icon-text gap.
      const padding = chips[0]!.paddingLeft;
      expect(padding).toBeGreaterThan(0);
      for (const chip of chips) {
        expect([chip.name, chip.paddingLeft, chip.paddingRight]).toEqual([chip.name, padding, padding]);
        expect([chip.name, chip.gap]).toEqual([chip.name, chips[0]!.gap]);
      }
      // Icon buttons: square, with no padding of their own.
      for (const icon of icons) {
        expect([icon.name, icon.width]).toEqual([icon.name, height]);
        expect([icon.name, icon.paddingLeft, icon.paddingRight]).toEqual([icon.name, 0, 0]);
      }
      // One radius and the hand cursor everywhere; no fill at rest.
      for (const control of all) {
        expect([control.name, control.radius]).toEqual([control.name, all[0]!.radius]);
        // The pointing hand on what a click works (the ring is off before the chat reports usage).
        expect([control.name, control.cursor]).toEqual([control.name, control.disabled ? "default" : "pointer"]);
        expect([control.name, control.background, clear(control.background)]).toEqual([
          control.name,
          control.background,
          true,
        ]);
      }
      // Hovered, each draws the same fill.
      const fills = new Map<string, string>();
      for (const [name, selector] of Object.entries(CONTROLS)) {
        const target = page.locator(selector).last();
        if (!(await target.isVisible()) || (await target.isDisabled())) continue;
        await target.hover();
        await settle(page);
        fills.set(name, await target.evaluate((element) => getComputedStyle(element).backgroundColor));
        await rest(page);
      }
      const hover = [...fills.values()][0]!;
      expect(clear(hover)).toBe(false);
      for (const [name, fill] of fills) expect([name, fill]).toEqual([name, hover]);
      await page.close();
    });

    test(`${engine}: the + sits the same distance from the box's left, top and bottom edges`, async () => {
      const page = await open(engine, "agent-pane.composer", "draft", 560);
      // One line of prompt.
      await page.click(".acpmux-composer-box .acpmux-md");
      await page.keyboard.press("ControlOrMeta+a");
      await page.keyboard.type("jlkj");
      await rest(page);
      const insets = await page.evaluate(() => {
        const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const plus = document.querySelector(".acpmux-composer-box .acpmux-composer-plus .acpmux-picker-button")!;
        const r = plus.getBoundingClientRect();
        const right = document.querySelector(".acpmux-composer-box .acpmux-composer-actions > :last-child")!;
        const a = right.getBoundingClientRect();
        return {
          left: r.left - box.left,
          top: r.top - box.top,
          bottom: box.bottom - r.bottom,
          right: box.right - a.right,
          actionsBottom: box.bottom - a.bottom,
        };
      });
      expect(insets.top).toBeCloseTo(insets.left, 0);
      expect(insets.bottom).toBeCloseTo(insets.left, 0);
      expect(insets.right).toBeCloseTo(insets.left, 0);
      expect(insets.actionsBottom).toBeCloseTo(insets.left, 0);
      await page.close();
    });

    test(`${engine}: while a turn runs, exactly one of Stop and Send shows`, async () => {
      const visible = (page: Page) =>
        page.evaluate(() => {
          const shown = (selector: string) =>
            [...document.querySelectorAll<HTMLElement>(`.acpmux-composer-box ${selector}`)].filter(
              (element) => element.getBoundingClientRect().width > 0,
            ).length;
          return {
            stop: shown(".acpmux-cancel"),
            send: shown(".acpmux-send:not(.acpmux-cancel)"),
            mic: shown(".acpmux-mic"),
          };
        });
      // Empty prompt: Stop alone, the mic beside it.
      let page = await open(engine, "agent-pane.composer", "working");
      expect(await visible(page)).toEqual({ stop: 1, send: 0, mic: 1 });
      // Typing brings Send (or ↵ for an agent that steers) in Stop's place.
      await page.click(".acpmux-composer-box .acpmux-md");
      await page.keyboard.type("jlkj");
      await rest(page);
      expect(await visible(page)).toEqual({ stop: 0, send: 1, mic: 1 });
      await page.close();
      for (const variant of ["working-steer", "working-queue"]) {
        page = await open(engine, "agent-pane.composer", variant);
        expect([variant, await visible(page)]).toEqual([variant, { stop: 0, send: 1, mic: 1 }]);
        await page.close();
      }
      // The running tray's row keeps its own □ off at rest while the composer shows Stop, and
      // shows it on hover, so one Stop shows at a time.
      page = await open(engine, "agent-pane.subagent-tray", "one-running");
      expect((await visible(page)).stop).toBe(1);
      const rowStop = page.locator(".acpmux-running-tray .cv-subagent__stop").first();
      const shown = () => rowStop.evaluate((element) => getComputedStyle(element).opacity !== "0");
      expect(await shown()).toBe(false);
      await page.locator(".acpmux-running-tray .acpmux-agent-line").first().hover();
      await settle(page);
      expect(await shown()).toBe(true);
      await page.close();
    });

    test(`${engine}: no composer control draws a "•"`, async () => {
      for (const [entry, variant] of [
        ["agent-pane.composer", "quiet-chips"],
        ["agent-pane.model-picker", "update-offer"],
      ] as const) {
        const page = await open(engine, entry, variant);
        const found = await page.evaluate(() => {
          // The controls' own faces: the box, the quiet row and the model button (not its open menu).
          const scope = [
            ...document.querySelectorAll(".acpmux-composer-box, .acpmux-composer-foot, .acpmux-model > button"),
          ];
          const text = scope.map((element) => element.textContent ?? "").join(" ");
          const dots = scope.flatMap((element) => [
            ...element.querySelectorAll(".acpmux-model-update-dot, [class*='bullet']"),
          ]);
          return {
            bullet: /[•·∙●]/.test(text),
            dots: dots.length,
            model: document.querySelector(".acpmux-model") !== null,
          };
        });
        expect([variant, found]).toEqual([variant, { bullet: false, dots: 0, model: true }]);
        await page.close();
      }
    });
  }
});
