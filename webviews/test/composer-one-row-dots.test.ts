// cmux-web-test-timeout: 300
// Claude's look is one row, and the look dots keep one place (Leo 2026-10-23: "I mean, like the claw
// thing should be one single row, and then the codex and the codex, the dot switches thing, like it
// should just be, like in the same kind of spot, but, like, it's just buried within the codex thing
// when it's there, like at the bottom area"):
//
// - New Tab in Claude's look: nothing over the composer's box; the folder, the computer and the model
//   are one row under it (newtab/screen.css, NewTabScreen.tsx).
// - New Tab with the composer at the page's foot, and a chat: the dots sit at the same place in the
//   pane in both looks, out of the flow on its bottom edge, 8 px tall, in the gutter under the
//   composer's last part: exactly the quiet row's 8 px margin in Claude's look, the 16 px under the
//   box in Codex's (composerLook.css). They add no line: the quiet row keeps its 8 px over the edge
//   (composer-bottom-space.test.ts). At 420 px they stay clear of Send and the scrollbar's lane.
// - The page's style dots beside them (the style dots widget) keep their 24 px targets and 14 px
//   focus ring; only the look dots take the gutter's 8 px and a 10 px ring.
// - A look switched by keys leaves the dots where they were, the keyboard on them, and Escape goes
//   back.
//
// Real Chromium on the gallery stage. CI fails the file when it cannot launch it
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-one-row-dots.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-one-row-dots.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer one row and dots", () => test("browser", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  const ENTRY = "agent-pane.composer-look";
  /** The look dots' height, and the gutter under the composer's last part in each look. */
  const DOTS = 8;
  const GUTTER = { claude: 8, codex: 16 } as const;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "newtab-stage-claude" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A gallery variant, its pointer parked in the corner. */
  const open = async (variant: string, { height = 520, width = 760, entry = ENTRY } = {}) => {
    const context = await browser.newContext({ viewport: { width, height } });
    const page = await context.newPage();
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.mouse.move(1, 1);
    return { page, close: () => context.close() };
  };
  const settle = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  /** Where the dots sit: the composer's last part's bottom (the quiet row, or the box with Codex's
   *  look), the pane's bottom edge, the dots' box, and their place in the pane. */
  const dotsPlace = (page: Page, composer: string, dots: string) =>
    page.evaluate(
      ({ composer, dots }) => {
        const host = document.querySelector(composer)!;
        const last = (host.querySelector(".acpmux-composer-foot") ??
          host.querySelector(".nt-box, .acpmux-composer-box"))!.getBoundingClientRect();
        const pane = document.querySelector(".acpmux-main")!.getBoundingClientRect();
        const group = document.querySelector(dots)!.getBoundingClientRect();
        const edge = Math.min(pane.bottom, window.innerHeight);
        return {
          gutter: edge - last.bottom,
          gap: group.top - last.bottom,
          under: edge - group.bottom,
          height: group.height,
          top: group.top - pane.top,
          left: group.left - pane.left,
        };
      },
      { composer, dots },
    );
  type Place = Awaited<ReturnType<typeof dotsPlace>>;
  const near = (value: number, want: number, what: string) => {
    expect(value, what).toBeGreaterThanOrEqual(want - 0.5);
    expect(value, what).toBeLessThanOrEqual(want + 0.5);
  };
  /** The dots on the pane's edge, 8 px tall, in the look's exact gutter, at one place in both looks. */
  const samePlace = (claude: Place, codex: Place) => {
    for (const [look, at] of [
      ["claude", claude],
      ["codex", codex],
    ] as const) {
      near(at.gutter, GUTTER[look], `${look}: the gutter under the composer's last part`);
      near(at.height, DOTS, `${look}: the dots' height`);
      near(at.under, 0, `${look}: the dots sit on the pane's edge`);
      near(at.gap, GUTTER[look] - DOTS, `${look}: the room between the composer and the dots`);
    }
    near(codex.top, claude.top, "the same top in both looks");
    near(codex.left, claude.left, "the same left in both looks");
  };

  test("New Tab, Claude's look: nothing over the box, the folder, computer and model one row under it", async () => {
    for (const variant of ["newtab-stage-claude", "newtab-claude"]) {
      const { page, close } = await open(variant);
      const layout = await page.evaluate(() => {
        const composer = document.querySelector(".nt-composer")!;
        const box = composer.querySelector(".nt-box")!.getBoundingClientRect();
        // Everything the composer draws over its box.
        const over = [...composer.querySelectorAll<HTMLElement>("*")].filter((element) => {
          const rect = element.getBoundingClientRect();
          return rect.height > 0 && rect.bottom <= box.top && !element.closest(".nt-box");
        });
        const middle = (selector: string) => {
          const rect = composer.querySelector(selector)?.getBoundingClientRect();
          return rect ? Math.round(rect.top + rect.height / 2) : undefined;
        };
        const rows = new Set(
          [".acpmux-location-picker:first-child", '.acpmux-location-picker[data-kind="computer"]', ".acpmux-model"].map(
            middle,
          ),
        );
        return {
          over: over.map((element) => element.className),
          rows: [...rows],
          underBox: [...rows].every((y) => y !== undefined && y > box.bottom),
          inFoot: composer.querySelectorAll(".acpmux-composer-foot :is(.nt-location, .acpmux-model)").length,
        };
      });
      expect({ variant, over: layout.over }).toEqual({ variant, over: [] });
      expect({ variant, rows: layout.rows.length, underBox: layout.underBox }).toEqual({
        variant,
        rows: 1,
        underBox: true,
      });
      expect(layout.inFoot).toBe(2);
      await close();
    }
  });

  test("New Tab: the dots keep one place in the page's 8 px gutter in both looks", async () => {
    const claude = await open("newtab-stage-claude");
    const atClaude = await dotsPlace(claude.page, ".nt-composer", ".nt-look-dots");
    await claude.close();
    const codex = await open("newtab-stage-codex");
    const atCodex = await dotsPlace(codex.page, ".nt-composer", ".nt-look-dots");
    await codex.close();
    samePlace(atClaude, atCodex);
  });

  test("in a chat the dots keep one place in the composer's 8 px gutter in both looks", async () => {
    const claude = await open("claude-chat", { height: 600 });
    const atClaude = await dotsPlace(claude.page, ".acpmux-composer", ".acpmux-look-dots");
    await claude.close();
    const codex = await open("codex-chat", { height: 600 });
    const atCodex = await dotsPlace(codex.page, ".acpmux-composer", ".acpmux-look-dots");
    await codex.close();
    samePlace(atClaude, atCodex);
  });

  test("at 420 px the dots stay clear of Send and the scrollbar's lane, in both looks", async () => {
    for (const [variant, dots] of [
      ["newtab-stage-claude", ".nt-look-dots"],
      ["newtab-stage-codex", ".nt-look-dots"],
      ["claude-chat", ".acpmux-look-dots"],
      ["codex-chat", ".acpmux-look-dots"],
    ] as const) {
      const { page, close } = await open(variant, { width: 420, height: 600 });
      // A draft, so the chat draws its Send (Claude's look shows it once there is something to send).
      if (variant.endsWith("-chat")) {
        await page.focus(".acpmux-composer [contenteditable]");
        await page.keyboard.type("Fix the flaky test");
        await settle(page);
      }
      const drawn = await page.evaluate((dots) => {
        const group = document.querySelector(dots)!.getBoundingClientRect();
        const pane = document.querySelector(".acpmux-main")!;
        const box = pane.getBoundingClientRect();
        // Every scroller in the pane that reaches down to the dots' height: its scrollbar's lane at
        // its right edge (its drawn width, or the minimal scroller's 8 px lane when it overlays).
        const lanes = [...pane.querySelectorAll<HTMLElement>("*")]
          .filter((element) => /auto|scroll/.test(getComputedStyle(element).overflowY))
          .map((element) => ({ element, rect: element.getBoundingClientRect() }))
          .filter(({ rect }) => rect.height > 0 && rect.bottom > group.top && rect.top < group.bottom)
          .map(({ element, rect }) => rect.right - Math.max(8, element.offsetWidth - element.clientWidth));
        const send = [...document.querySelectorAll(".acpmux-send")]
          .map((element) => element.getBoundingClientRect())
          .filter((rect) => rect.width > 0 && rect.height > 0);
        const overlaps = send.filter(
          (rect) =>
            rect.left < group.right && group.left < rect.right && rect.top < group.bottom && group.top < rect.bottom,
        );
        return {
          send: send.length,
          overlaps: overlaps.length,
          lane: Math.min(box.right - 8, ...lanes) - group.right,
          inside: group.left - box.left,
        };
      }, dots);
      await close();
      expect({ variant, send: drawn.send > 0 }).toEqual({ variant, send: true });
      expect({ variant, overlaps: drawn.overlaps }).toEqual({ variant, overlaps: 0 });
      expect(drawn.lane, `${variant}: clear of the scrollbar's lane`).toBeGreaterThanOrEqual(0);
      expect(drawn.inside, `${variant}: inside the pane`).toBeGreaterThanOrEqual(0);
    }
  });

  test("with the style dots on, they keep 24 px targets and a 14 px ring; the look dots take 8 px and 10 px", async () => {
    const { page, close } = await open("minimal-widgets", { height: 640, entry: "agent-pane.new-tab" });
    const look = ".nt-page-dots > .nt-look-dots";
    const style = ".nt-page-dots > .nt-style:not(.nt-look-dots)";
    await page.locator(`${style} .nt-style-option`).first().waitFor();
    const sizes = await page.evaluate(
      ({ look, style }) => {
        const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
        const middle = (r: DOMRect) => r.top + r.height / 2;
        const lookOption = rect(`${look} .nt-style-option`);
        const styleOption = rect(`${style} .nt-style-option`);
        const styleMark = rect(`${style} .nt-style-mark`);
        return {
          look: { width: lookOption.width, height: lookOption.height },
          style: { width: styleOption.width, height: styleOption.height },
          styleMark: { width: styleMark.width, height: styleMark.height },
          line: middle(lookOption) - middle(styleOption),
          foot: document.querySelector(".acpmux-composer-foot")!.getBoundingClientRect().bottom,
          styleTop: rect(style).top,
        };
      },
      { look, style },
    );
    expect(sizes.style).toEqual({ width: 24, height: 24 });
    expect(sizes.styleMark).toEqual({ width: 24, height: 24 });
    expect(sizes.look.height).toBe(DOTS);
    near(sizes.line, 0, "both groups' dots on one line");
    expect(sizes.foot, "the quiet row clear of the style dots").toBeLessThanOrEqual(sizes.styleTop + 0.5);

    /** The focus ring's size on the focused dot (the option's ::before), with the keyboard on it. */
    const ring = async (group: string) => {
      await page.focus(`${group} .nt-style-input`);
      return page.evaluate((group) => {
        const input = document.querySelector<HTMLInputElement>(`${group} .nt-style-input:focus`);
        const option = input?.closest(".nt-style-option");
        if (!input || !option || !input.matches(":focus-visible")) return undefined;
        const before = getComputedStyle(option, "::before");
        return { width: before.width, height: before.height };
      }, group);
    };
    expect(await ring(style)).toEqual({ width: "14px", height: "14px" });
    expect(await ring(look)).toEqual({ width: "10px", height: "10px" });
    await close();
  });

  test("arrow keys switch the look with the dots held in place and the keyboard on them; Escape goes back", async () => {
    // A chat: Claude's dot, then Codex's by ArrowRight and back by ArrowLeft.
    const chat = await open("claude-chat", { height: 600 });
    const { page } = chat;
    const form = ".acpmux-composer";
    const place = () => dotsPlace(page, form, ".acpmux-look-dots");
    const focused = () =>
      page.evaluate(() => {
        const active = document.activeElement as HTMLInputElement | null;
        if (active?.matches(".nt-style input[type=radio]")) return `dot:${active.value}`;
        if (active?.matches("[contenteditable], textarea")) return "prompt";
        return active?.tagName ?? "none";
      });
    await page.focus(`${form} .acpmux-look-dots input[value=claude]`);
    const start = await place();
    await page.keyboard.press("ArrowRight");
    await page.waitForSelector(`${form}[data-composer-look="codex"]`);
    await settle(page);
    expect(await focused()).toBe("dot:codex");
    const switched = await place();
    near(switched.top, start.top, "the dots' top after the switch");
    near(switched.left, start.left, "the dots' left after the switch");
    await page.keyboard.press("ArrowLeft");
    await page.waitForFunction((selector) => !document.querySelector(`${selector}[data-composer-look]`), form);
    await settle(page);
    expect(await focused()).toBe("dot:claude");
    const back = await place();
    near(back.top, start.top, "the dots' top after switching back");
    near(back.left, start.left, "the dots' left after switching back");
    await page.keyboard.press("Escape");
    await settle(page);
    expect(await focused()).toBe("prompt");
    await chat.close();

    // New Tab: the arrow keys reach Codex's look with the dots in place and the keyboard on them.
    const tab = await open("newtab-stage-claude");
    const newTab = tab.page;
    const dots = () => dotsPlace(newTab, ".nt-composer", ".nt-look-dots");
    await newTab.focus(".nt-look-dots input[value=claude]");
    const before = await dots();
    for (let press = 0; press < 3; press++) {
      if (await newTab.$('.nt-composer[data-composer-look="codex"]')) break;
      await newTab.keyboard.press("ArrowRight");
      await settle(newTab);
    }
    await newTab.waitForSelector('.nt-composer[data-composer-look="codex"]');
    expect(
      await newTab.evaluate(() => (document.activeElement as HTMLInputElement | null)?.matches(".nt-look-dots input")),
    ).toBe(true);
    const after = await dots();
    near(after.top, before.top, "the New Tab dots' top after the switch");
    near(after.left, before.left, "the New Tab dots' left after the switch");
    near(after.gutter, GUTTER.codex, "Codex's gutter after the switch");
    await newTab.keyboard.press("Escape");
    await settle(newTab);
    expect(
      await newTab.evaluate(() => (document.activeElement as HTMLInputElement | null)?.matches(".nt-look-dots input")),
    ).toBe(false);
    await tab.close();
  });
});
