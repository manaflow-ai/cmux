// Austin 2026-11-10, a long prompt in the New Tab composer with the suggestions open: "we need to fix
// this up arrow, down arrow behavior on the agent chat composer main menu. we had good behavior
// before where up arrow would go up on the textbox and going down to the bottom would hit the menu".
//
// A prompt the field wraps onto several lines had no newline, so ↑ and ↓ never moved its caret: the
// first ↑ left the top row typing lights, the next took the menu's last row. Now ↑ and ↓ walk the
// wrapped lines like a text box, and ↓ on the last line reaches the menu (↑ on the first, its last row).
//
// Real Chromium and WebKit from Playwright on the gallery stage (jsdom has no layout, so no wrapping).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-wrapped-prompt-arrows.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-wrapped-prompt-arrows.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `new-tab-wrapped-prompt-arrows: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab wrapped prompt arrows", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const width = 560;
  const stageURL = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default", frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    const browser = browsers.get("chromium") ?? browsers.get("webkit");
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "minimal-default" } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const field = ".nt-field .acpmux-md";
  // The highlighted suggestion (-1: none) and the caret's offset in the prompt.
  const state = (page: Page) =>
    page.evaluate(() => {
      const rows = [...document.querySelectorAll("[aria-selected]")].filter((row) => row.closest("#nt-rows"));
      const handle = (
        document.querySelector(".nt-field") as HTMLElement & {
          acpmuxMarkdownField?: { text(): { value: string; selectionStart: number } };
        }
      ).acpmuxMarkdownField!;
      const text = handle.text();
      return {
        highlighted: rows.findIndex((row) => row.getAttribute("aria-selected") === "true"),
        rows: rows.length,
        caret: text.selectionStart,
        length: text.value.length,
        newline: text.value.includes("\n"),
      };
    });
  // A key, then the field's state once the browser's selectionchange reached the editor: ProseMirror
  // reads a caret the browser moved from that event, which can land after the key resolves. The
  // caret's top on screen goes to the log, so a failure says which line the browser drew it on.
  const press = async (page: Page, key: string, before: number) => {
    await page.keyboard.press(key);
    await page.evaluate(() => window.cmuxPaintFrame());
    await page
      .waitForFunction(
        (prev) => {
          const handle = (
            document.querySelector(".nt-field") as HTMLElement & {
              acpmuxMarkdownField?: { text(): { selectionStart: number } };
            }
          ).acpmuxMarkdownField!;
          return handle.text().selectionStart !== prev;
        },
        before,
        { timeout: 2_000 },
      )
      .catch(() => undefined);
    const top = await page.evaluate(() => {
      const range = getSelection()?.rangeCount ? getSelection()!.getRangeAt(0) : undefined;
      return range ? Math.round(range.getClientRects()[0]?.top ?? range.getBoundingClientRect().top) : undefined;
    });
    const after = await state(page);
    console.log(
      `new-tab-wrapped-prompt-arrows: ${key} caret ${before} -> ${after.caret}, top ${top}, row ${after.highlighted}`,
    );
    return after;
  };
  const lineCount = (page: Page) =>
    page.evaluate((selector) => {
      const node = document.querySelector<HTMLElement>(selector)!;
      return Math.round(node.getBoundingClientRect().height / parseFloat(getComputedStyle(node).lineHeight));
    }, field);

  for (const [engine] of engines) {
    test(`${engine}: ↑ and ↓ walk a wrapped prompt's lines before the menu takes them`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 640 } });
      await installPaintedFrames(page);
      await page.goto(stageURL());
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(field).first().waitFor();
      await page.evaluate(() => document.fonts.ready);
      await page.click(field);
      await page.keyboard.insertText(
        "we need to fix this up arrow, down arrow behavior on the agent chat composer main menu. we had good behavior before where up arrow would go up on the textbox",
      );
      await page.evaluate(() => window.cmuxPaintFrame());

      const typed = await state(page);
      const lines = await lineCount(page);
      // One paragraph the field wraps: no newline, three lines or more, the caret at its end.
      expect(typed.newline).toBe(false);
      expect(lines).toBeGreaterThanOrEqual(3);
      expect(typed.caret).toBe(typed.length);
      expect(typed.rows).toBeGreaterThan(1);
      expect(typed.highlighted).toBe(0);

      // ↑ from the last line moves the caret up a line each time; the top row typing lit stays.
      const carets = [typed.caret];
      for (let line = 1; line < lines; line++) {
        const after = await press(page, "ArrowUp", carets.at(-1)!);
        expect({ line, highlighted: after.highlighted }).toEqual({ line, highlighted: 0 });
        expect(after.caret).toBeLessThan(carets.at(-1)!);
        carets.push(after.caret);
      }
      // ↓ walks back down to the last line, still in the text.
      let caret = carets.at(-1)!;
      for (let line = 1; line < lines; line++) {
        const after = await press(page, "ArrowDown", caret);
        caret = after.caret;
        expect({ line, highlighted: after.highlighted }).toEqual({ line, highlighted: 0 });
        expect(after.caret).toBeGreaterThan(carets[lines - line]!);
      }
      // ↓ on the last line reaches the menu: the next row.
      await page.keyboard.press("ArrowDown");
      expect((await state(page)).highlighted).toBe(1);
      await page.close();
    });
  }
});
