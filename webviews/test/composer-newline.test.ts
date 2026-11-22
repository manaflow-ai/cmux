// cmux-web-test-timeout: 300
// Leo, 2026-11-22: "NEW LINE SITUATION IN THE COMPOSER IS TOO FUCKING SHIT IT PUTS ME FUCKING PARTWAY
// IF EVEN AND JUST FUCKING DOESNT SEND ME TO THE NEXT THING IDK IF IT'S THE STUPID FUCKING WYSIWYG
// EDITOR THAT WE NEED TO FUCKING IMPROVE OR WHAT JUST FIX THE SITUATION AND EVERY POSSIBLE SITUATION"
//
// Shift-Return and Option-Return put the caret at the start of a new line, every time: at the end of
// the text, in its middle, in a list item or a quote, after an emoji, an attachment chip or a trailing
// space, in an empty composer, with the @ or / menu open, right after an input method commits (WebKit:
// ProseMirror drops a key within 500 ms of compositionend, and the browser's own line break then
// reached the composer as a Return), during a composition (the input method keeps its key), and with
// the field at its full height and scrolled. The new line is inside the field's visible box once the
// field settles. Nothing is sent.
//
// The page is the pane's dev entry with the in-page mock transport. Real Chromium and WebKit (the
// app's engine) from Playwright; CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-newline.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR, COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

/** Where the caret is after the key, read once the field stopped moving. */
type Seen = {
  /** The prompt's plain text (blocks and breaks as `\n`) and the caret's offset into it. */
  text: string;
  caret: number;
  /** The caret's box (the drawn caret's on a line with a chip) in the field's scrolled content. */
  top: number;
  bottom: number;
  left: number;
  /** The left edge of the text in the caret's block (its content box), in the same space. */
  lineLeft: number;
  /** The caret's box lies inside the scroller's visible box. */
  inView: boolean;
  /** How the caret's box sits against the scroller's, for a failure's message. */
  view: { caretTop: number; caretBottom: number; boxTop: number; boxBottom: number };
  /** Prompts the composer sent (the mock transport's prompt requests). */
  sent: number;
  /** The caret's block, as a tag path (`blockquote > p`, `li > p`). */
  block: string;
};

await requireBrowserLane("composer-newline.test.ts", async () => {
  const KEYS = ["Shift+Enter", "Alt+Enter"] as const;

  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    try {
      await (await engine.launch({ headless: true, timeout: 30_000 })).close();
      engines.push([name, engine]);
    } catch {
      if (process.env.GITHUB_ACTIONS === "true") throw new Error(`composer-newline: ${name} did not launch`);
      console.warn(`composer-newline: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (!engines.length) {
    describe.skip("composer new line", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function newChat(engine: string): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 640 } });
    await page.addInitScript(() => {
      const sent: unknown[] = [];
      Object.assign(window, {
        __sent: sent,
        webkit: {
          messageHandlers: {
            agentSession: {
              postMessage: async (message: { method?: string; params?: unknown }) => {
                if (typeof message?.method === "string" && /prompt|send/i.test(message.method)) sent.push(message);
                return { ok: true, value: null };
              },
            },
          },
        },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(COMPOSER_EDITOR).waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.locator(COMPOSER_EDITOR).click();
    return page;
  }

  /** Waits until the field's height and scroll held still for a few frames (its growth motion ended). */
  const still = (page: Page) =>
    page.evaluate(
      (scrollerSelector) =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(scrollerSelector)!;
          let last = "";
          let same = 0;
          const started = performance.now();
          const step = () => {
            const box = scroller.getBoundingClientRect();
            const now = `${box.top}:${box.height}:${scroller.scrollTop}`;
            same = now === last ? same + 1 : 0;
            last = now;
            if (same >= 6 || performance.now() - started > 2_000) resolve();
            // raf-read: the field's settling, frame by frame.
            else requestAnimationFrame(step);
          };
          // raf-read: from the key's frame.
          requestAnimationFrame(step);
        }),
      COMPOSER_MD_FIELD,
    );

  /** Runs in the page: the caret as it is drawn, against its line and the field's visible box. */
  function measure([editorSelector, scrollerSelector]: [string, string]): Seen {
    const editable = document.querySelector<HTMLElement>(editorSelector)!;
    const scroller = document.querySelector<HTMLElement>(scrollerSelector)!;
    const handle = (scroller as HTMLElement & { acpmuxMarkdownField?: any }).acpmuxMarkdownField!;
    const prompt = handle.text() as { value: string; selectionStart: number };
    const selection = getSelection()!;
    const range = selection.getRangeAt(0);
    const node = range.startContainer;
    const element = node.nodeType === 1 ? (node as Element) : node.parentElement!;
    const block = element.closest("p, h1, h2, h3, h4, h5, h6, pre, li")!;
    const blockBox = block.getBoundingClientRect();
    const blockStyle = getComputedStyle(block);
    let caret: { top: number; bottom: number; left: number } | undefined;
    // The drawn caret (composer/inlineCaret.ts) stands for the native one on a line with a chip.
    const drawn = scroller.querySelector<HTMLElement>(".acpmux-md-caret");
    if (drawn && !drawn.hidden && drawn.getBoundingClientRect().height > 0) caret = drawn.getBoundingClientRect();
    if (!caret) {
      const rect = [...range.getClientRects()].at(-1);
      if (rect && rect.height > 0) caret = rect;
    }
    if (!caret) {
      // An empty line: its caret is at the block's first line, at its content's left.
      const line = parseFloat(blockStyle.lineHeight) || parseFloat(blockStyle.fontSize) * 1.2;
      const top = blockBox.top + parseFloat(blockStyle.paddingTop);
      caret = { top, bottom: top + line, left: blockBox.left + parseFloat(blockStyle.paddingLeft) };
    }
    const box = scroller.getBoundingClientRect();
    const path: string[] = [];
    for (let at: Element | null = block; at && at !== editable; at = at.parentElement)
      path.unshift(at.tagName.toLowerCase());
    const y = (value: number) => value - box.top + scroller.scrollTop;
    return {
      text: prompt.value,
      caret: prompt.selectionStart,
      top: y(caret.top),
      bottom: y(caret.bottom),
      left: caret.left - box.left,
      lineLeft: blockBox.left + parseFloat(blockStyle.paddingLeft) + parseFloat(blockStyle.borderLeftWidth) - box.left,
      inView: caret.top >= box.top - 1 && caret.bottom <= box.bottom + 1,
      view: { caretTop: caret.top, caretBottom: caret.bottom, boxTop: box.top, boxBottom: box.bottom },
      sent: ((window as unknown as { __sent: unknown[] }).__sent ?? []).length,
      block: path.join(" > "),
    };
  }
  const read = async (page: Page) => {
    await still(page);
    return page.evaluate(measure, [COMPOSER_EDITOR, COMPOSER_MD_FIELD] as [string, string]);
  };

  /** Presses `key` and checks the caret moved to the start of a new line, `text` the prompt after. */
  /// `prepare` runs between the reading before and the key, with no wait between it and the key.
  async function newLine(
    page: Page,
    key: string,
    expected: { text: string; caret: number; block?: string },
    prepare?: () => Promise<void>,
  ) {
    const before = await read(page);
    await prepare?.();
    await page.keyboard.press(key);
    const after = await read(page);
    expect({ text: after.text, caret: after.caret }).toEqual({ text: expected.text, caret: expected.caret });
    // At the line's start: the text before the caret ends with the line's break.
    expect(after.text.slice(0, after.caret).endsWith("\n")).toBe(true);
    if (expected.block) expect(after.block).toBe(expected.block);
    // A whole line down, at the left of the line's text.
    expect(after.top).toBeGreaterThanOrEqual(before.bottom - 2);
    expect(Math.abs(after.left - after.lineLeft)).toBeLessThanOrEqual(3);
    // Shown: inside the field's visible box.
    expect({ inView: after.inView, view: after.view }).toEqual({ inView: true, view: after.view });
    expect(after.sent).toBe(before.sent);
    return after;
  }

  /** Types `text` into the prompt as keys (Markdown input rules apply, as they do for a person). */
  const type = (page: Page, text: string) => page.keyboard.type(text, { delay: 5 });

  /** Puts a small picture in the prompt as a pasted attachment chip, at the caret. */
  async function pasteChip(page: Page) {
    await page.evaluate(async (prompt) => {
      const canvas = document.createElement("canvas");
      canvas.width = 640;
      canvas.height = 360;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a6ea5";
      context.fillRect(0, 0, 640, 360);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "shot.png", { type: "image/png" }));
      const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
      if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
      document.querySelector(prompt)!.dispatchEvent(paste);
    }, COMPOSER_EDITOR);
    await page.waitForFunction(
      () => {
        const chip = document.querySelector(".acpmux-composer-box [data-inline-attachment] img") as HTMLImageElement;
        return Boolean(chip?.complete && chip.naturalWidth > 0);
      },
      undefined,
      { polling: 20, timeout: 30_000 },
    );
  }

  /** Fires a composition that commits `text` the way the editor sees an input method's (events, then text). */
  async function composeAndCommit(page: Page, text: string) {
    await page.evaluate((prompt) => {
      const field = document.querySelector(prompt)!;
      field.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    }, COMPOSER_EDITOR);
    await page.keyboard.insertText(text);
    await page.evaluate(
      ({ prompt, text }) => {
        const field = document.querySelector(prompt)!;
        field.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: text }));
      },
      { prompt: COMPOSER_EDITOR, text },
    );
  }

  for (const [engine] of engines) {
    for (const key of KEYS) {
      describe(`${engine} ${key}`, () => {
        test("at the end of the text", async () => {
          const page = await newChat(engine);
          await type(page, "hello there");
          await newLine(page, key, { text: "hello there\n", caret: 12 });
          await type(page, "next");
          expect((await read(page)).text).toBe("hello there\nnext");
          await page.close();
        });

        test("in the middle of the text", async () => {
          const page = await newChat(engine);
          await type(page, "hello there");
          for (let index = 0; index < 5; index++) await page.keyboard.press("ArrowLeft");
          await newLine(page, key, { text: "hello \nthere", caret: 7 });
          await page.close();
        });

        test("in a list item", async () => {
          const page = await newChat(engine);
          await type(page, "- first item");
          await newLine(page, key, { text: "first item\n", caret: 11, block: "ul > li > p" });
          await type(page, "second");
          await newLine(page, key, { text: "first item\nsecond\n", caret: 18, block: "ul > li > p" });
          await page.close();
        });

        test("in a quote", async () => {
          const page = await newChat(engine);
          await type(page, "> quoted words");
          await newLine(page, key, { text: "quoted words\n", caret: 13, block: "blockquote > p" });
          await page.close();
        });

        test("after an emoji", async () => {
          const page = await newChat(engine);
          await type(page, "ship it ");
          await page.keyboard.insertText("🚀");
          const caret = "ship it 🚀".length + 1;
          await newLine(page, key, { text: "ship it 🚀\n", caret });
          await page.close();
        });

        test("after an attachment chip", async () => {
          const page = await newChat(engine);
          await type(page, "look ");
          await pasteChip(page);
          const before = await read(page);
          await page.keyboard.press(key);
          const after = await read(page);
          expect(after.text.slice(0, after.caret).endsWith("\n")).toBe(true);
          expect(after.caret).toBe(after.text.length);
          expect(after.top).toBeGreaterThanOrEqual(before.bottom - 2);
          expect(Math.abs(after.left - after.lineLeft)).toBeLessThanOrEqual(3);
          expect({ inView: after.inView, view: after.view }).toEqual({ inView: true, view: after.view });
          // The chip's line keeps its chip; the drawn caret left with the caret.
          expect(await page.locator(".acpmux-composer-box [data-inline-attachment]").count()).toBe(1);
          expect(after.sent).toBe(before.sent);
          await page.close();
        });

        test("with the @ mention menu open", async () => {
          const page = await newChat(engine);
          await type(page, "ask @rea");
          await newLine(page, key, { text: "ask @rea\n", caret: 9 });
          await page.close();
        });

        test("with the / command menu open", async () => {
          const page = await newChat(engine);
          await type(page, "/rev");
          await newLine(page, key, { text: "/rev\n", caret: 5 });
          await page.close();
        });

        test("after a trailing space", async () => {
          const page = await newChat(engine);
          await type(page, "trailing ");
          await newLine(page, key, { text: "trailing \n", caret: 10 });
          await page.close();
        });

        test("in an empty composer", async () => {
          const page = await newChat(engine);
          await newLine(page, key, { text: "\n", caret: 1 });
          await newLine(page, key, { text: "\n\n", caret: 2 });
          await type(page, "third");
          expect((await read(page)).text).toBe("\n\nthird");
          await page.close();
        });

        test("right after an input method commits", async () => {
          const page = await newChat(engine);
          await type(page, "say ");
          // The key comes within ProseMirror's 500 ms after-composition window (its WebKit guard drops
          // any key there), as a person's Shift-Return right after picking a candidate does.
          await newLine(page, key, { text: "say こんにちは\n", caret: 10 }, () => composeAndCommit(page, "こんにちは"));
          await page.close();
        });

        test("during a composition, the input method keeps the key", async () => {
          const page = await newChat(engine);
          await type(page, "say ");
          await page.evaluate((prompt) => {
            document
              .querySelector(prompt)!
              .dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
          }, COMPOSER_EDITOR);
          await page.keyboard.insertText("かな");
          const before = await read(page);
          // An input method's key: keyCode 229, isComposing.
          await page.evaluate(
            ({ prompt, alt }) => {
              const field = document.querySelector(prompt)!;
              field.dispatchEvent(
                new KeyboardEvent("keydown", {
                  key: "Enter",
                  code: "Enter",
                  keyCode: 229,
                  shiftKey: !alt,
                  altKey: alt,
                  isComposing: true,
                  bubbles: true,
                  cancelable: true,
                }),
              );
            },
            { prompt: COMPOSER_EDITOR, alt: key === "Alt+Enter" },
          );
          const during = await read(page);
          expect(during.text).toBe(before.text);
          expect(during.sent).toBe(before.sent);
          await page.evaluate((prompt) => {
            document
              .querySelector(prompt)!
              .dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "かな" }));
          }, COMPOSER_EDITOR);
          expect((await read(page)).text).toBe("say かな");
          await page.close();
        });

        test("with the field at its full height, scrolled", async () => {
          const page = await newChat(engine);
          // Past the field's cap: it scrolls inside.
          for (let index = 0; index < 16; index++) {
            if (index) await page.keyboard.press("Shift+Enter");
            await page.keyboard.insertText(`line ${index + 1}`);
          }
          const capped = await page.evaluate((selector) => {
            const scroller = document.querySelector<HTMLElement>(selector)!;
            return scroller.scrollHeight > scroller.clientHeight + 1;
          }, COMPOSER_MD_FIELD);
          expect(capped).toBe(true);
          const lines = Array.from({ length: 16 }, (_, index) => `line ${index + 1}`);
          // At the end: the new last line shows.
          let text = `${lines.join("\n")}\n`;
          await newLine(page, key, { text, caret: text.length });
          // In the middle, scrolled away from it first: the line it opens shows.
          await page.keyboard.press("Backspace");
          await page.keyboard.press("ControlOrMeta+Home");
          for (let index = 0; index < 3; index++) await page.keyboard.press("ArrowDown");
          await page.keyboard.press("End");
          await page.evaluate((selector) => {
            const scroller = document.querySelector<HTMLElement>(selector)!;
            scroller.scrollTop = scroller.scrollHeight;
          }, COMPOSER_MD_FIELD);
          text = [...lines.slice(0, 4), "", ...lines.slice(4)].join("\n");
          await newLine(page, key, { text, caret: lines.slice(0, 4).join("\n").length + 1 });
          await page.close();
        });
      });
    }
  }
});
