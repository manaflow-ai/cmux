// cmux-web-test-timeout: 300
// After a model pick the keyboard is in the prompt (Lawrence 2026-10-22: "after selecting a model my
// keyboard should be focused in text area"), whatever had focus before the menu opened and however
// the pick was made: a press, a key or a search in the model button's menu, a press or Enter in
// the full picker. Escape and a press outside still behave as menu-pointer-close-focus.test.ts says,
// a full picker reopened before a pick's focus lands included.
// Real Chromium and WebKit (the app's engine) on the gallery stage, the chat's composer and the New
// Tab's. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/model-pick-prompt-focus.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-pick-prompt-focus.test.ts", async () => {
  setDefaultTimeout(280_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`model pick prompt focus: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("model pick prompt focus", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant, frame: "component", width: 760, theme: "Catppuccin Mocha" })}`;

  type Stage = { name: string; entry: string; variant: string; prompt: string };
  const STAGES: Stage[] = [
    {
      name: "chat composer",
      entry: "agent-pane.composer",
      variant: "quiet-chips",
      prompt: ".acpmux-composer-box .acpmux-md",
    },
    { name: "New Tab composer", entry: "agent-pane.new-tab", variant: "reasoning-chip", prompt: ".nt-field" },
  ];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    // The New Tab first, as composer-caret-focus does: the chat composer's frame then loads warm.
    for (const stage of [...STAGES].reverse())
      await warmGalleryFrame(vite, stage.entry, {
        browser: [...browsers.values()][0],
        params: { variant: stage.variant },
        timeoutMs: 200_000,
      });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const MODEL = ".acpmux-model .acpmux-picker-button";
  const QUICK = ".acpmux-quick-menu";
  const QUICK_ROW = `${QUICK} [role=menuitemradio]:not([aria-checked=true]):not([data-disabled])`;
  const FULL = ".acpmux-mp";
  const FULL_ROW = `${FULL} .acpmux-mp-row[data-key^="model:"]:not([aria-checked=true]):not(:disabled)`;

  const open = async (engine: string, stage: Stage): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(stageURL(stage.entry, stage.variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // Nothing focused, so a menu that only returns focus where it was never reaches the prompt.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    return page;
  };
  /** Until no menu is still opening or closing and two frames have painted after. */
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const moving = document.querySelector("[data-starting-style], [data-ending-style]");
        if (!moving && finite().every((animation) => animation.playState !== "running")) return;
      }
    });
  /** A real press and release at the centre of `selector`. */
  const press = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).first().boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await settled(page);
  };
  /** Whether the keyboard is in the prompt, and what has focus (its first class) when it is not. */
  const focus = (page: Page, prompt: string) =>
    page.evaluate((selector) => {
      const active = document.activeElement;
      const field = document.querySelector(selector);
      return {
        inPrompt: !!active && !!field && (active === field || field.contains(active)),
        focused: String(active?.className ?? "").split(" ")[0] ?? "",
      };
    }, prompt);
  /** "prompt" when the keyboard is in it, else the focused element's first class (or "body"). */
  const where = async (page: Page, prompt: string) => {
    const state = await focus(page, prompt);
    return state.inPrompt ? "prompt" : state.focused || "body";
  };
  const openFull = async (page: Page) => {
    await press(page, MODEL);
    await page.locator(QUICK).first().waitFor();
    await page.keyboard.press("Escape");
    await page.locator(QUICK).first().waitFor({ state: "detached" });
    // Cmd-Ctrl-M opens the full picker (ModelPicker), from any composer.
    await page.keyboard.press("Meta+Control+KeyM");
    await page.locator(FULL).first().waitFor();
    await settled(page);
  };

  for (const [engine] of engines)
    for (const stage of STAGES) {
      test(`${engine}: ${stage.name}: a pick with the mouse in the model menu puts the keyboard in the prompt`, async () => {
        const page = await open(engine, stage);
        await press(page, MODEL);
        await page.locator(QUICK).first().waitFor();
        await press(page, QUICK_ROW);
        await page.locator(QUICK).first().waitFor({ state: "detached" });
        await settled(page);
        expect(await where(page, stage.prompt)).toBe("prompt");
        await page.close();
      });

      test(`${engine}: ${stage.name}: a pick with the keys in the model menu puts the keyboard in the prompt`, async () => {
        const page = await open(engine, stage);
        await press(page, MODEL);
        await page.locator(QUICK).first().waitFor();
        // Down to the first model row the chat is not on, then Enter.
        for (let step = 0; step < 12; step++) {
          if (await page.evaluate((row) => !!document.activeElement?.matches(row), QUICK_ROW)) break;
          await page.keyboard.press("ArrowDown");
        }
        await page.keyboard.press("Enter");
        await page.locator(QUICK).first().waitFor({ state: "detached" });
        await settled(page);
        expect(await where(page, stage.prompt)).toBe("prompt");
        await page.close();
      });

      test(`${engine}: ${stage.name}: a pick from the model menu's search puts the keyboard in the prompt`, async () => {
        const page = await open(engine, stage);
        await press(page, MODEL);
        await page.locator(QUICK).first().waitFor();
        // Search for a model the chat is not on; the keyboard starts in the menu's search field.
        const name = (await page.locator(`${QUICK_ROW} .acpmux-menu-label`).first().textContent()) ?? "";
        await page.keyboard.type(name);
        await page.locator(QUICK_ROW, { hasText: name }).first().waitFor();
        for (let step = 0; step < 12; step++) {
          if (await page.evaluate((row) => !!document.activeElement?.matches(row), QUICK_ROW)) break;
          await page.keyboard.press("ArrowDown");
        }
        await page.keyboard.press("Enter");
        await page.locator(QUICK).first().waitFor({ state: "detached" });
        await settled(page);
        expect(await where(page, stage.prompt)).toBe("prompt");
        await page.close();
      });

      test(`${engine}: ${stage.name}: a pick with the mouse in the full picker puts the keyboard in the prompt`, async () => {
        const page = await open(engine, stage);
        await openFull(page);
        await press(page, FULL_ROW);
        await page.locator(FULL).first().waitFor({ state: "detached" });
        await settled(page);
        expect(await where(page, stage.prompt)).toBe("prompt");
        await page.close();
      });

      test(`${engine}: ${stage.name}: Enter in the full picker puts the keyboard in the prompt`, async () => {
        const page = await open(engine, stage);
        await openFull(page);
        await page.keyboard.press("ArrowDown");
        await page.keyboard.press("Enter");
        await page.locator(FULL).first().waitFor({ state: "detached" });
        await settled(page);
        expect(await where(page, stage.prompt)).toBe("prompt");
        await page.close();
      });

      test(`${engine}: ${stage.name}: Escape still puts the keyboard on the model button`, async () => {
        const page = await open(engine, stage);
        await press(page, MODEL);
        await page.locator(QUICK).first().waitFor();
        await page.keyboard.press("Escape");
        await page.locator(QUICK).first().waitFor({ state: "detached" });
        await settled(page);
        expect(
          await page.evaluate((selector) => document.activeElement === document.querySelector(selector), MODEL),
        ).toBe(true);
        await page.close();
      });

      test(`${engine}: ${stage.name}: a full picker reopened before a pick's focus lands still closes to the model button`, async () => {
        const page = await open(engine, stage);
        await openFull(page);
        // Hold the page's animation frames, so the pick's deferred focus has not run when the
        // picker opens again (Cmd-Ctrl-M) and Escape closes it. Both are window and document
        // key listeners, so they need no frame; the held frames run once Escape has closed it.
        // Every wait below is a DOM state the picker reaches without a frame: it mounts and
        // unmounts with `open`, and its anchor shows it from a layout effect (ui/anchor.ts).
        // Playwright retries a locator wait from its own side, not on the page's frames.
        type Held = { releaseFrames: () => void; heldFrames: () => number };
        await page.evaluate(() => {
          const held = new Map<number, FrameRequestCallback>();
          const real = { request: window.requestAnimationFrame, cancel: window.cancelAnimationFrame };
          let next = 1e9;
          window.requestAnimationFrame = (callback) => {
            held.set(++next, callback);
            return next;
          };
          window.cancelAnimationFrame = (id) => {
            if (!held.delete(id)) real.cancel.call(window, id);
          };
          Object.assign(window, {
            heldFrames: () => held.size,
            releaseFrames: () => {
              window.requestAnimationFrame = real.request;
              window.cancelAnimationFrame = real.cancel;
              for (const callback of held.values()) real.request.call(window, callback);
              held.clear();
            },
          });
        });
        await page.keyboard.press("ArrowDown");
        await page.keyboard.press("Enter");
        // The pick has closed the picker, and its deferred focus waits in a held frame.
        await page.locator(FULL).first().waitFor({ state: "detached" });
        expect(await page.evaluate(() => (window as unknown as Held).heldFrames())).toBeGreaterThan(0);
        await page.keyboard.press("Meta+Control+KeyM");
        // Open again, with its keys live: the search field takes focus in a layout effect once the
        // picker shows, after the open's effects (its Escape listener) have run.
        await page.locator(`${FULL} input:focus`).first().waitFor({ state: "attached" });
        await page.keyboard.press("Escape");
        await page.locator(FULL).first().waitFor({ state: "detached" });
        await page.evaluate(() => (window as unknown as Held).releaseFrames());
        await settled(page);
        expect(
          await page.evaluate((selector) => document.activeElement === document.querySelector(selector), MODEL),
        ).toBe(true);
        await page.close();
      });
    }
});
