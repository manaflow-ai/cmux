// cmux-web-test-timeout: 480
// The chat composer never overflows sideways and never loses its caret
// (https://github.com/manaflow-ai/cmux/issues/28672): whatever is typed or pasted wraps inside the
// prompt's text column, clear of + and the actions, the box grows with it up to its cap and then
// scrolls inside, and the caret stays in view, also when the draft rewraps with no edit (Send takes
// the mic's place on the first character, the pane narrows, the window gets shorter). Text typed up
// to Send wraps before the actions: no glyph is ever painted under a button or its hover pill, also
// after the box lost its measured inset (composerScrollLane.ts puts it back).
//
// Each case types or pastes into the gallery's chat composer the way a person does (real key
// presses for spaces, Shift-Enter and Enter; a real paste event; Chromium's IME composition), then
// reads the prompt's geometry: every glyph and the caret must sit inside the text column, nothing in
// the box may scroll or spill sideways, the page must not widen, and the caret must be inside the
// field's visible box.
//
// Real Chromium and WebKit (the app's engine) from Playwright; CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-draft-overflow.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Geometry = {
  text: string;
  /** Laid-out lines of the draft. */
  lines: number;
  /** The scroller's border-box height, its max-height, and its scroll box. */
  height: number;
  max: number;
  scrollHeight: number;
  clientHeight: number;
  /** What spills sideways: a box wider than its client box or scrolled sideways, the page wider than its window. */
  sideways: string[];
  /** How far (px) the farthest glyph sits outside the text column. */
  textPast: number;
  /** The caret is inside the scroller's visible box (`shown`) and the text column (`inColumn`). */
  caret: { shown: boolean; inColumn: boolean } | null;
  /** The text column ends before the actions (Send, Stop) where they sit beside it. */
  clearOfActions: boolean;
};

await requireBrowserLane("composer-draft-overflow.test.ts", async () => {
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
      console.warn(`composer-draft-overflow: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer draft overflow", () => test("browsers", () => {}));
    return;
  }

  const FIELD = ".acpmux-composer-box .acpmux-md";
  const SCROLLER = ".acpmux-composer-box .acpmux-md-field";

  /** Runs in the page: the prompt's geometry. */
  function measure([fieldSelector, scrollerSelector]: [string, string]): Geometry {
    const field = document.querySelector<HTMLElement>(fieldSelector)!;
    const scroller = document.querySelector<HTMLElement>(scrollerSelector)!;
    const box = scroller.closest<HTMLElement>(".acpmux-composer-box")!;
    const style = getComputedStyle(scroller);
    const fieldStyle = getComputedStyle(field);
    const line = parseFloat(fieldStyle.lineHeight) || parseFloat(fieldStyle.fontSize) * 1.2;
    const outer = scroller.getBoundingClientRect();
    // The text column: the scroller's content box, which the actions' column is padded out of.
    const left = outer.left + scroller.clientLeft + parseFloat(style.paddingLeft);
    const right = outer.left + scroller.clientLeft + scroller.clientWidth - parseFloat(style.paddingRight);
    const visibleTop = outer.top + scroller.clientTop;
    const visibleBottom = visibleTop + scroller.clientHeight;
    const sideways: string[] = [];
    const name = (element: Element) => `${element.tagName.toLowerCase()}.${String(element.className).split(" ")[0]}`;
    for (const element of [box, scroller, field, ...field.querySelectorAll("p, li, blockquote")]) {
      if (!(element instanceof HTMLElement)) continue;
      if (element.scrollWidth > element.clientWidth + 1)
        sideways.push(`${name(element)} scrollWidth ${element.scrollWidth} > ${element.clientWidth}`);
      if (element.scrollLeft > 0) sideways.push(`${name(element)} scrollLeft ${element.scrollLeft}`);
    }
    const boxRect = box.getBoundingClientRect();
    const composer = box.parentElement!.getBoundingClientRect();
    if (boxRect.right > composer.right + 1)
      sideways.push(`box right ${boxRect.right} > its parent's ${composer.right}`);
    const page = document.scrollingElement ?? document.documentElement;
    if (page.scrollWidth > page.clientWidth + 1)
      sideways.push(`page scrollWidth ${page.scrollWidth} > ${page.clientWidth}`);
    let textPast = 0;
    const walker = document.createTreeWalker(field, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width === 0) continue;
        textPast = Math.max(textPast, rect.right - right, left - rect.left);
      }
    }
    // The caret, at the draft's end in every case here: its last glyph's right edge, or an empty
    // last line's own box (a Shift-Enter just pressed). The DOM selection is not read: WebKit can
    // report the end of a paragraph as its start (\`P, 0\`) while ProseMirror's caret is at its end.
    const caretRect = (): { top: number; bottom: number; left: number } | undefined => {
      const last = field.lastElementChild;
      if (!last) return undefined;
      const texts: Text[] = [];
      const lastWalker = document.createTreeWalker(last, NodeFilter.SHOW_TEXT);
      for (let node = lastWalker.nextNode(); node; node = lastWalker.nextNode())
        if ((node as Text).length) texts.push(node as Text);
      const text = texts.at(-1);
      if (!text) {
        const block = last.getBoundingClientRect();
        return { top: block.top, bottom: Math.min(block.bottom, block.top + line), left: block.left };
      }
      const end = document.createRange();
      end.setStart(text, text.length - 1);
      end.setEnd(text, text.length);
      const rect = [...end.getClientRects()].filter((r) => r.height > 0).at(-1);
      return rect && { top: rect.top, bottom: rect.bottom, left: rect.right };
    };
    const caret = caretRect();
    const actions = box.querySelector<HTMLElement>(".acpmux-composer-actions")?.getBoundingClientRect();
    const besideText = !!actions && actions.top < outer.bottom && actions.bottom > outer.top;
    return {
      text: field.innerText.replace(/\n$/, ""),
      lines: Math.round(field.getBoundingClientRect().height / line),
      height: outer.height,
      max: parseFloat(style.maxHeight),
      scrollHeight: scroller.scrollHeight,
      clientHeight: scroller.clientHeight,
      sideways,
      textPast,
      caret: caret
        ? {
            shown: caret.top >= visibleTop - 1 && caret.bottom <= visibleBottom + 1,
            inColumn: caret.left >= left - 1 && caret.left <= right + 1,
          }
        : null,
      clearOfActions: !besideText || right <= actions!.left + 1,
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
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    // A cold Vite compiles the pane (App.tsx alone is past Babel's 500 KB) inside this budget.
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, timeoutMs: 200_000 });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "codex-chat" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Surface = { name: string; entry: string; variant: string };
  const IDLE: Surface = { name: "the chat composer", entry: "agent-pane.composer", variant: "idle" };
  const surfaces: { surface: Surface; widths: number[] }[] = [
    { surface: IDLE, widths: [240, 300, 760] },
    // Stop beside Send (and steer's ↵ once there is a draft): the widest actions.
    {
      surface: { name: "the composer while a turn runs", entry: "agent-pane.composer", variant: "working-steer" },
      widths: [300],
    },
    {
      surface: { name: "the composer with prompts queued", entry: "agent-pane.composer", variant: "queued" },
      widths: [300],
    },
    // Codex's look: Claude's grid, the actions beside the prompt.
    { surface: { name: "Codex's composer", entry: "agent-pane.composer-look", variant: "codex-chat" }, widths: [300] },
  ];

  const open = async (engine: string, surface: Surface, width: number, height = 640) => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height } });
    await installPaintedFrames(page);
    await page.goto(stageURL(surface.entry, surface.variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(FIELD).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.click(FIELD);
    // Some fixtures arrive with a kept draft: each case starts from an empty prompt.
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    return page;
  };
  /** The geometry as the next frame paints it, after the draft and its observers settled. */
  const read = async (page: Page) => {
    await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => window.cmuxPaintFrame());
    return page.evaluate(measure, [FIELD, SCROLLER] as [string, string]);
  };
  const paste = (page: Page, text: string) =>
    page.evaluate(
      ([selector, text]) => {
        const field = document.querySelector<HTMLElement>(selector)!;
        const data = new DataTransfer();
        data.setData("text/plain", text);
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      [FIELD, text] as [string, string],
    );
  /** No sideways spill, every glyph and the caret in the text column, the caret in view. */
  const contained = (geometry: Geometry, label: string) => {
    expect({ label, sideways: geometry.sideways }).toEqual({ label, sideways: [] });
    expect({ label, textPast: geometry.textPast <= 1 }).toEqual({ label, textPast: true });
    expect({ label, caret: geometry.caret }).toEqual({ label, caret: { shown: true, inColumn: true } });
    expect({ label, clearOfActions: geometry.clearOfActions }).toEqual({ label, clearOfActions: true });
    // Grown with the draft, or standing at its cap and scrolling inside.
    if (geometry.scrollHeight > geometry.clientHeight + 1)
      expect({ label, atCap: Math.abs(geometry.height - geometry.max) <= 1 }).toEqual({ label, atCap: true });
  };

  const URL_TEXT =
    "https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/webviews/src/agent-session/acpmux/ComposerBox.tsx?plain=1&line=190#L190-L216-and-a-very-long-anchor-with-no-breaks-at-all";
  const WORD = "supercalifragilistic".repeat(16);
  const CLUSTER = "👩🏽‍💻";
  const SPACES = 100;

  for (const [engine] of engines) {
    for (const { surface, widths } of surfaces)
      for (const width of widths)
        test(`${engine}: ${surface.name} at ${width} px wraps spaces, long words, a URL and emoji inside the box`, async () => {
          const page = await open(engine, surface, width);
          await page.keyboard.type("Spaces follow");
          for (let index = 0; index < SPACES; index++) await page.keyboard.press("Space");
          const trailing = await read(page);
          contained(trailing, "trailing spaces");
          // Every space is kept, none collapsed or dropped.
          expect(trailing.text.replace(/ /g, " ")).toBe(`Spaces follow${" ".repeat(SPACES)}`);
          await page.keyboard.type("end");
          const spaced = await read(page);
          contained(spaced, "spaces then a word");
          if (width <= 300) expect(spaced.lines).toBeGreaterThan(1);
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.insertText(WORD);
          contained(await read(page), "a long word");
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.insertText(URL_TEXT);
          contained(await read(page), "a URL");
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.insertText(CLUSTER.repeat(40));
          const emoji = await read(page);
          contained(emoji, "emoji");
          expect(emoji.text.endsWith(CLUSTER.repeat(40))).toBe(true);
          // Backspace takes one whole cluster, never part of one.
          await page.keyboard.press("Backspace");
          const back = await read(page);
          contained(back, "emoji after Backspace");
          expect(back.text.endsWith(`\n${CLUSTER.repeat(39)}`)).toBe(true);
          await page.close();
        });

    for (const width of [240, 760])
      test(`${engine}: a long word put into an empty prompt at ${width} px keeps the caret in view as Send replaces the mic`, async () => {
        const page = await open(engine, IDLE, width);
        await page.keyboard.insertText(WORD.repeat(width < 400 ? 1 : 3));
        const typed = await read(page);
        contained(typed, "inserted");
        expect(typed.lines).toBeGreaterThan(1);
        await page.close();
      });

    test(`${engine}: Shift-Enter adds a line, Enter adds none`, async () => {
      const page = await open(engine, IDLE, 300);
      await page.keyboard.type("first line");
      const one = await read(page);
      await page.keyboard.press("Shift+Enter");
      contained(await read(page), "after Shift-Enter");
      await page.keyboard.type("second line");
      const two = await read(page);
      contained(two, "second line");
      expect(two.text.split("\n").filter(Boolean)).toEqual(["first line", "second line"]);
      expect(two.height).toBeGreaterThan(one.height + 4);
      // Enter is the send key: it adds no line (composer-return-sends.test.tsx checks the send; the
      // gallery's chat takes no prompt, so the draft stays here).
      await page.keyboard.press("Enter");
      const sent = await read(page);
      expect(sent.text.split("\n").filter(Boolean)).toEqual(["first line", "second line"]);
      expect(Math.abs(sent.height - two.height)).toBeLessThanOrEqual(1);
      await page.close();
    });

    test(`${engine}: a long multi-line paste stops at the cap and scrolls inside, its end in view`, async () => {
      const page = await open(engine, IDLE, 300);
      const start = await read(page);
      // Under the chip's 20 lines and 2,000 characters (pastedText.ts): it goes in as text.
      const lines = Array.from({ length: 18 }, (_, index) => `line ${index + 1} ${"x".repeat(60)}`);
      await paste(page, lines.join("\n"));
      await page.waitForFunction(
        (selector) => document.querySelector(selector)?.textContent?.includes("line 18"),
        FIELD,
      );
      const pasted = await read(page);
      contained(pasted, "multi-line paste");
      expect(pasted.scrollHeight).toBeGreaterThan(pasted.clientHeight + 1);
      expect(pasted.max).toBeGreaterThan(start.height * 3);
      await page.close();
    });

    test(`${engine}: a long one-line paste with no spaces wraps and scrolls inside`, async () => {
      const page = await open(engine, IDLE, 300);
      await paste(page, "a".repeat(1900));
      await page.waitForFunction(
        (selector) => (document.querySelector(selector)?.textContent?.length ?? 0) >= 1900,
        FIELD,
      );
      const pasted = await read(page);
      contained(pasted, "one-line paste");
      expect(pasted.scrollHeight).toBeGreaterThan(pasted.clientHeight + 1);
      await page.close();
    });

    test(`${engine}: the caret at the end of a long draft stays in view as the pane narrows and shortens`, async () => {
      const page = await open(engine, IDLE, 760, 900);
      await page.keyboard.type("A long line ");
      await page.keyboard.insertText(`${"word ".repeat(40)}${WORD}`);
      contained(await read(page), "wide");
      await page.setViewportSize({ width: 260, height: 900 });
      contained(await read(page), "narrowed");
      // The field's cap is part of the window's height (markdownField.css): a shorter window lowers it.
      await page.setViewportSize({ width: 260, height: 420 });
      const shortened = await read(page);
      contained(shortened, "shortened");
      expect(shortened.scrollHeight).toBeGreaterThan(shortened.clientHeight + 1);
      await page.keyboard.type("!");
      contained(await read(page), "typed after the resize");
      await page.close();
    });

    test(`${engine}: a rewrap leaves a draft the person scrolled up where they put it`, async () => {
      const page = await open(engine, IDLE, 760, 900);
      await page.keyboard.insertText(`${"word ".repeat(300)}`);
      await read(page);
      // A wheel up to the draft's start, then the pane narrows: the field keeps showing its start.
      const box = await page.locator(SCROLLER).boundingBox();
      await page.mouse.move(box!.x + box!.width / 2, box!.y + box!.height / 2);
      await page.mouse.wheel(0, -5000);
      await page.waitForFunction((selector) => document.querySelector(selector)!.scrollTop === 0, SCROLLER);
      await page.setViewportSize({ width: 300, height: 900 });
      await read(page);
      expect(await page.evaluate((selector) => document.querySelector(selector)!.scrollTop, SCROLLER)).toBe(0);
      await page.close();
    });

    if (engine === "chromium")
      test(`${engine}: an IME composition at the end of a long line wraps, and its Return commits it, adding no line`, async () => {
        const page = await open(engine, IDLE, 300);
        await page.keyboard.insertText(WORD);
        const cdp = await page.context().newCDPSession(page);
        for (let index = 0; index < 12; index++) {
          await cdp.send("Input.imeSetComposition", { text: "にほんご", selectionStart: 4, selectionEnd: 4 });
          contained(await read(page), `composing ${index}`);
          if (index === 11) {
            // The Return an input method commits with (keyCode 229) is the input method's.
            await cdp.send("Input.dispatchKeyEvent", {
              type: "rawKeyDown",
              key: "Enter",
              code: "Enter",
              windowsVirtualKeyCode: 229,
              nativeVirtualKeyCode: 229,
            });
            await cdp.send("Input.dispatchKeyEvent", {
              type: "keyUp",
              key: "Enter",
              code: "Enter",
              windowsVirtualKeyCode: 229,
            });
          }
          await cdp.send("Input.insertText", { text: "日本語" });
        }
        const committed = await read(page);
        contained(committed, "committed");
        expect(committed.text).toBe(`${WORD}${"日本語".repeat(12)}`);
        await page.close();
      });
  }

  /** Starts a sampler that, after every painted frame, records the widest overlap (px) of a typed
   *  glyph with any of the box's action buttons (whose hover and focus pills draw over the prompt). */
  const watchButtonEdge = (page: Page) =>
    page.evaluate((selector) => {
      const w = window as unknown as { underButton: { px: number; note: string } };
      w.underButton = { px: 0, note: "" };
      const check = () => {
        const field = document.querySelector<HTMLElement>(selector);
        const box = field?.closest(".acpmux-composer-box");
        if (!field || !box) return;
        const visible = field.closest<HTMLElement>(".acpmux-md-field")!.getBoundingClientRect();
        const buttons = [...box.querySelectorAll<HTMLElement>(".acpmux-composer-actions button")]
          .map((button) => ({ label: button.getAttribute("aria-label") ?? "", rect: button.getBoundingClientRect() }))
          .filter(({ rect }) => rect.width > 0);
        const walker = document.createTreeWalker(field, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const text = node as Text;
          for (let index = 0; index < text.length; index++) {
            if (/\s/.test(text.data[index]!)) continue;
            const range = document.createRange();
            range.setStart(text, index);
            range.setEnd(text, index + 1);
            for (const glyph of range.getClientRects()) {
              if (glyph.width === 0 || glyph.bottom <= visible.top || glyph.top >= visible.bottom) continue;
              for (const { label, rect } of buttons) {
                const x = Math.min(glyph.right, rect.right) - Math.max(glyph.left, rect.left);
                const y = Math.min(glyph.bottom, rect.bottom) - Math.max(glyph.top, rect.top);
                if (x > 0.5 && y > 0.5 && x > w.underButton.px)
                  w.underButton = { px: x, note: `${JSON.stringify(text.data[index])} under ${label}` };
              }
            }
          }
        }
      };
      // After every painted frame (`open` installed the painted-frame reader).
      window.cmuxAfterPaint(check);
    }, FIELD);
  const underButton = (page: Page) =>
    page.evaluate(() => (window as unknown as { underButton: { px: number; note: string } }).underButton);
  /** Typing that runs up to the actions' edge: words, an unbroken run and a run of spaces. */
  const typeToTheEdge = async (page: Page) => {
    await page.keyboard.type("near the edge of the box the words keep going until they wrap ".repeat(2), { delay: 5 });
    await page.keyboard.type("x".repeat(60), { delay: 5 });
    for (let index = 0; index < 30; index++) await page.keyboard.press("Space");
    await page.keyboard.type("tail", { delay: 5 });
  };
  const EDGE: { surface: Surface; width: number; params?: string }[] = [
    { surface: IDLE, width: 260 },
    { surface: IDLE, width: 420 },
    {
      surface: { name: "the composer while a turn runs", entry: "agent-pane.composer", variant: "working-steer" },
      width: 300,
    },
    {
      surface: { name: "the composer with prompts queued", entry: "agent-pane.composer", variant: "queued" },
      width: 300,
    },
  ];

  for (const [engine] of engines) {
    for (const { surface, width } of EDGE)
      test(`${engine}: ${surface.name} at ${width} px: text typed up to Send wraps, never under a button, with the pointer on Send`, async () => {
        const page = await open(engine, surface, width);
        // `open` focused the prompt with a click; the pointer then rests on the last action (Send, or
        // the mic before there is a draft), so its hover pill shows while the text runs up to it.
        const last = await page.locator(".acpmux-composer-box .acpmux-composer-actions button").last().boundingBox();
        if (last) await page.mouse.move(last.x + last.width / 2, last.y + last.height / 2);
        await watchButtonEdge(page);
        await typeToTheEdge(page);
        await read(page);
        expect(await underButton(page)).toEqual({ px: 0, note: "" });
        contained(await read(page), "typed to the edge");
        await page.close();
      });

    test(`${engine}: the actions' inset comes back when the box loses it, while Stop and ↵ widen the actions`, async () => {
      const page = await open(engine, EDGE[2]!.surface, 300);
      await page.keyboard.type("steer");
      await read(page);
      // Another field leaving the same box clears the box's inset (composerScrollLane.ts cleanup);
      // the CSS fallback is narrower than ↵, Stop and the mic.
      await page.evaluate(() =>
        document.querySelector<HTMLElement>(".acpmux-composer-box")!.style.removeProperty("--acpmux-actions-width"),
      );
      await watchButtonEdge(page);
      await typeToTheEdge(page);
      await read(page);
      expect(await underButton(page)).toEqual({ px: 0, note: "" });
      contained(await read(page), "after the inset was cleared");
      await page.close();
    });
  }
});
