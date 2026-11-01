// cmux-web-test-timeout: 240
// A typed draft is never cut (Austin): the composer shows all of it. A long one-line draft wraps
// onto as many lines as it needs, focused or not; the field grows with it up to its cap and then
// scrolls inside, the caret kept in view; nothing draws it as one clipped or ellipsized line.
//
// The New Tab page is where every chat starts (its default style), so its field is the composer
// most drafts are typed into; the chat composer is checked too, idle, while a turn runs and with
// prompts queued. Both run from the gallery stage at a narrow (300 px) and a normal (760 px) pane.
//
// Real Chromium and WebKit (the app's engine) from Playwright; CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-draft-wrap.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Field = {
  /** The draft as the field holds it. */
  text: string;
  /** The scroller's border-box height, its max-height (NaN for none), and its content's. */
  height: number;
  max: number;
  scrollHeight: number;
  clientHeight: number;
  overflowY: string;
  /** Lines of text the draft is laid out on. */
  lines: number;
  /** The draft runs past the field's side (one line scrolled or cut). */
  clippedSide: boolean;
  /** Elements of the field that cut text: an ellipsis, nowrap, or a line clamp. */
  cutters: string[];
  /** The caret (at the draft's end) is inside the scroller's visible box. */
  caretShown: boolean;
};

await requireBrowserLane("composer-draft-wrap.test.ts", async () => {
  const LONG =
    "Please refactor the fetch helper so that every GET retries with exponential backoff and jitter, " +
    "keep POST requests idempotent only behind an explicit policy flag, update the README and add " +
    "tests for the 429 and 503 paths";
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
      console.warn(`composer-draft-wrap: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer draft wrap", () => test("browsers", () => {}));
    return;
  }

  /** Runs in the page: the draft field's geometry. `field` holds the text; `scroller` caps it. */
  function measure([fieldSelector, scrollerSelector]: [string, string]): Field {
    const field = document.querySelector<HTMLElement>(fieldSelector)!;
    const scroller = document.querySelector<HTMLElement>(scrollerSelector)!;
    const style = getComputedStyle(scroller);
    const fieldStyle = getComputedStyle(field);
    const line = parseFloat(fieldStyle.lineHeight) || parseFloat(fieldStyle.fontSize) * 1.2;
    const text =
      field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement
        ? field.value
        : (field.textContent ?? "");
    // Lines: a text control's content box over its line height; an editor's laid-out height.
    const content =
      field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement
        ? field.scrollHeight - parseFloat(fieldStyle.paddingTop) - parseFloat(fieldStyle.paddingBottom)
        : field.getBoundingClientRect().height;
    const cutters: string[] = [];
    for (const element of [scroller, field, ...field.querySelectorAll("*")]) {
      const own = getComputedStyle(element);
      const name = `${element.tagName.toLowerCase()}.${String(element.className).split(" ")[0]}`;
      if (own.textOverflow === "ellipsis") cutters.push(`${name} text-overflow: ellipsis`);
      if (own.whiteSpace === "nowrap" || own.whiteSpace === "pre")
        cutters.push(`${name} white-space: ${own.whiteSpace}`);
      const clamp = own.getPropertyValue("-webkit-line-clamp");
      if (clamp && clamp !== "none") cutters.push(`${name} line-clamp: ${clamp}`);
    }
    return {
      text,
      height: scroller.getBoundingClientRect().height,
      max: parseFloat(style.maxHeight),
      scrollHeight: scroller.scrollHeight,
      clientHeight: scroller.clientHeight,
      overflowY: style.overflowY,
      lines: Math.round(content / line),
      clippedSide: field.scrollWidth > field.clientWidth + 1 || field.scrollLeft > 0,
      cutters,
      caretShown: (() => {
        // An editor's caret is the selection's rect; a text control's, at the draft's end, is its
        // last line, shown when the scroller reaches it (its bottom padding may stay hidden).
        const selection = getSelection();
        const range = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : undefined;
        const caret = range && field.contains(range.endContainer) ? range.getClientRects()[0] : undefined;
        const box = scroller.getBoundingClientRect();
        if (caret && caret.height > 0) return caret.top >= box.top - 1 && caret.bottom <= box.bottom + 1;
        const end = scroller.scrollHeight - parseFloat(style.paddingBottom);
        return scroller.scrollTop + scroller.clientHeight >= end - 1;
      })(),
    };
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
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "empty" } });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const surfaces = [
    {
      name: "the New Tab field",
      entry: "agent-pane.new-tab",
      variant: "empty",
      field: ".nt-field .acpmux-md",
      scroller: ".nt-field",
    },
    {
      name: "the chat composer",
      entry: "agent-pane.composer",
      variant: "idle",
      field: ".acpmux-md",
      scroller: ".acpmux-md-field",
    },
    {
      name: "the chat composer while a turn runs",
      entry: "agent-pane.composer",
      variant: "working-steer",
      field: ".acpmux-md",
      scroller: ".acpmux-md-field",
    },
    {
      name: "the chat composer with prompts queued",
      entry: "agent-pane.composer",
      variant: "queued",
      field: ".acpmux-md",
      scroller: ".acpmux-md-field",
    },
  ];

  const open = async (engine: string, surface: (typeof surfaces)[number], width: number) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 520 } });
    await installPaintedFrames(page);
    await page.goto(stageURL(surface.entry, surface.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(surface.field).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.click(surface.field);
    // Some running-turn fixtures intentionally arrive with a kept draft. This measurement starts
    // from an empty prompt so it tests wrapping and growth rather than inserting into the clicked
    // position of that fixture text. Draft hydration itself is covered by agent-pane-unsent-draft.
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    return page;
  };
  const read = (page: Page, surface: (typeof surfaces)[number]) =>
    page.evaluate(measure, [surface.field, surface.scroller] as [string, string]);
  /** The field as the next frame paints it, after the draft or the blur has rendered. */
  const painted = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
  const blur = async (page: Page) => {
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await painted(page);
  };

  type Surface = (typeof surfaces)[number];
  /** A long one-line draft, read focused and then blurred. */
  const wrapped = async (engine: string, surface: Surface, width: number) => {
    const page = await open(engine, surface, width);
    await page.keyboard.insertText(LONG);
    await painted(page);
    const focused = await read(page, surface);
    await blur(page);
    const blurred = await read(page, surface);
    await page.close();
    return { focused, blurred };
  };
  /** The draft typed word by word: the last state that fits, the first that does not, and that one blurred. */
  const capped = async (engine: string, surface: Surface, width: number) => {
    const page = await open(engine, surface, width);
    const start = await read(page, surface);
    const words = LONG.split(" ");
    let under: Field | undefined;
    let over: Field | undefined;
    for (let index = 0; index < 600 && !over; index++) {
      await page.keyboard.insertText(`${index === 0 ? "" : " "}${words[index % words.length]}`);
      const field = await read(page, surface);
      if (field.scrollHeight > field.clientHeight + 1) over = field;
      else under = field;
    }
    await blur(page);
    const blurredOver = over ? await read(page, surface) : undefined;
    await page.close();
    return { start, under, over, blurredOver };
  };

  // Each case opens its own page (its own browser context, so focus and typing stay apart), and a
  // fresh page refetches the stage's ~700 modules. One after another, 32 of them after the cold
  // warm-up ran past the runner's 120 s file limit. So a few pages measure at once, and each test
  // awaits its own measurement and checks it.
  const PAGES = 4;
  const cases = engines.flatMap(([engine]) =>
    surfaces.flatMap((surface) => [300, 760].map((width) => ({ engine, surface, width }))),
  );
  const key = (engine: string, surface: Surface, width: number) => `${engine} ${surface.name} ${width}`;
  const wraps = new Map<string, ReturnType<typeof wrapped>>();
  const caps = new Map<string, ReturnType<typeof capped>>();
  beforeAll(() => {
    let free = PAGES;
    const waiting: (() => void)[] = [];
    const inPage = async <T>(work: () => Promise<T>) => {
      if (free > 0) free--;
      else await new Promise<void>((resolve) => waiting.push(resolve));
      try {
        return await work();
      } finally {
        const next = waiting.shift();
        if (next) next();
        else free++;
      }
    };
    // A test filtered out with -t never awaits its measurement; its failure must not go unhandled.
    for (const { engine, surface, width } of cases) {
      const wrap = inPage(() => wrapped(engine, surface, width));
      wrap.catch(() => {});
      wraps.set(key(engine, surface, width), wrap);
      const cap = inPage(() => capped(engine, surface, width));
      cap.catch(() => {});
      caps.set(key(engine, surface, width), cap);
    }
  });

  for (const { engine, surface, width } of cases) {
    test(`${engine}: ${surface.name} at ${width} px wraps a long one-line draft, whole, focused and blurred`, async () => {
      const { focused, blurred } = await wraps.get(key(engine, surface, width))!;
      for (const [state, field] of [
        ["focused", focused],
        ["blurred", blurred],
      ] as const) {
        expect({ state, text: field.text.replace(/\s+/g, " ").trim() }).toEqual({ state, text: LONG });
        expect({ state, cutters: field.cutters }).toEqual({ state, cutters: [] });
        expect({ state, clippedSide: field.clippedSide }).toEqual({ state, clippedSide: false });
        // Even the 760 px pane needs more than one line for it.
        expect(field.lines).toBeGreaterThan(1);
        // The field grew with it: every line shows, or the field stands at its cap and scrolls.
        if (field.scrollHeight > field.clientHeight + 1)
          expect(Math.abs(field.height - field.max)).toBeLessThanOrEqual(1);
      }
      // Blurring keeps the draft's full height: no collapsed one-line preview.
      expect(blurred.lines).toBe(focused.lines);
      expect(Math.abs(blurred.height - focused.height)).toBeLessThanOrEqual(1);
    });

    test(`${engine}: ${surface.name} at ${width} px grows to its cap, then scrolls with the caret in view`, async () => {
      const { start, under, over, blurredOver } = await caps.get(key(engine, surface, width))!;
      expect(over).toBeDefined();
      expect(under).toBeDefined();
      // The cap is a real height, a sensible number of lines, not one line.
      expect(Number.isFinite(over!.max)).toBe(true);
      expect(over!.max).toBeGreaterThan(start.height * 3);
      // Just under the cap: grown past one line, no scrollbar, below the cap.
      expect(under!.lines).toBeGreaterThan(4);
      expect(under!.height).toBeLessThan(over!.max + 0.5);
      expect(under!.scrollHeight).toBeLessThanOrEqual(under!.clientHeight + 1);
      expect(under!.cutters).toEqual([]);
      // Just over it: the field stops at the cap and scrolls inside, the caret in view.
      expect(Math.abs(over!.height - over!.max)).toBeLessThanOrEqual(1);
      expect(["auto", "scroll"]).toContain(over!.overflowY);
      expect(over!.caretShown).toBe(true);
      expect(over!.cutters).toEqual([]);
      expect(over!.clippedSide).toBe(false);
      // Blurred at the cap: still the capped, scrollable, wrapped field.
      expect(Math.abs(blurredOver!.height - over!.max)).toBeLessThanOrEqual(1);
      expect(blurredOver!.lines).toBe(over!.lines);
      expect(blurredOver!.cutters).toEqual([]);
    });
  }
});
