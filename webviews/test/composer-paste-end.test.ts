// cmux-web-test-timeout: 240
// A paste shows its end (Leo 2026-10-20, as in Claude Code desktop): after pasting a long text
// into the composer, the field scrolls so the last pasted line is in view, with the caret right
// after it. The field caps at eight lines and scrolls inside (.acpmux-md-field); Milkdown's
// clipboard plugin dispatched the paste without asking ProseMirror to scroll, so a 40-line paste
// into a 3-line draft left the field at its top, the caret and the pasted end out of sight.
//
// Real Chromium and WebKit (the app's engine) from Playwright; CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-paste-end.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-paste-end.test.ts", async () => {
  const LAST_LINE = "pasted line 15";
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      throw new Error(`composer-paste-end: cannot launch ${engine[0]}`);
    }
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const base = () => `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;

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
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    await page.goto(base());
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").waitFor();
    return page;
  }

  for (const [engine] of engines)
    test(`${engine}: a 15-line paste into a 3-line draft scrolls to its end, the caret after it`, async () => {
      const page = await newChat(engine);
      const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
      await prompt.click();
      // A short draft first: it fits the field, which has not scrolled.
      for (const [index, line] of ["draft line 1", "draft line 2", "draft line 3"].entries()) {
        if (index > 0) await page.keyboard.press("Shift+Enter");
        await page.keyboard.type(line);
      }
      await page.evaluate((last) => {
        const field = document.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable='true']")!;
        const data = new DataTransfer();
        // Under the chip's 750 words and 10,000 characters (pastedText.ts): a larger paste is a chip,
        // not prompt text. The field shows pasted lines joined as one paragraph, so they are long
        // enough to wrap past its eight lines (40 short lines did that before the chip).
        const lines = Array.from(
          { length: 15 },
          (_, index) => `pasted line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        );
        lines[14] = last;
        data.setData("text/plain", lines.join("\n"));
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      }, LAST_LINE);
      await page.waitForFunction(
        (last) =>
          document.querySelector(".acpmux-composer-prompt [contenteditable='true']")?.textContent?.includes(last),
        LAST_LINE,
      );
      // Let layout and any scroll settle.
      await page.evaluate(
        () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(undefined)))),
      );
      const seen = await page.evaluate((last) => {
        const editable = document.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable='true']")!;
        const scroller = editable.closest<HTMLElement>(".acpmux-md-field")!;
        const box = scroller.getBoundingClientRect();
        const inside = (rect: DOMRect | undefined) =>
          !!rect && rect.height > 0 && rect.top >= box.top - 1 && rect.bottom <= box.bottom + 1;
        // The last pasted line's own text, wherever the field put it.
        const walker = document.createTreeWalker(editable, NodeFilter.SHOW_TEXT);
        let lastLine: DOMRect | undefined;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const at = node.textContent?.indexOf(last) ?? -1;
          if (at < 0) continue;
          const range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + last.length);
          lastLine = range.getClientRects()[0];
        }
        const selection = getSelection();
        const range = selection?.rangeCount ? selection.getRangeAt(0) : undefined;
        const caret = range && editable.contains(range.endContainer) ? range.getClientRects()[0] : undefined;
        const handle = (scroller as MarkdownFieldElement).acpmuxMarkdownField!;
        const text = handle.text();
        return {
          scrolled: scroller.scrollHeight > scroller.clientHeight,
          scrollTop: scroller.scrollTop,
          lastLineShown: inside(lastLine),
          caretShown: inside(caret),
          caretAtEnd: text.selectionStart === text.value.length && text.selectionEnd === text.value.length,
          endsWithLast: text.value.endsWith(last),
        };
      }, LAST_LINE);
      // The paste overflows the field's cap, so it scrolls inside.
      expect(seen.scrolled).toBe(true);
      expect(seen.endsWithLast).toBe(true);
      // The caret sits right after the pasted text...
      expect(seen.caretAtEnd).toBe(true);
      // ...and the field scrolled down to show it and the last pasted line.
      expect(seen.scrollTop).toBeGreaterThan(0);
      expect(seen.caretShown).toBe(true);
      expect(seen.lastLineShown).toBe(true);
      await page.close();
    });
});
