// Text selection that starts in the markdown page's padding (user 2026-10-27: "Make it easier to
// select text in Markdown viewer. You should be able to click from the padding part and still be
// able to select the text properly."). The real page (gallery entry pages.markdown) in Chromium and
// WebKit, wider than the reading column so it has gutters on both sides:
//
// - a drag that starts in the left gutter, beside a line, selects from that line's start;
// - a drag that starts in the right gutter selects from that line's end;
// - a drag that starts below the last block selects up from the end of the document;
// - double click in the gutter selects the nearest word, triple click its block;
// - Shift-click in the gutter extends the selection;
// - the same in a read-only file.
//
// Before, the press landed on the column's padding (`.md-doc`) or the scroller around it, outside
// the editable element: the drag selected nothing, or text outside the document.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("markdown-padding-select.test.ts", async () => {
  const ENTRY_PATH = "src/pages/markdown/markdown.gallery.ts";
  setDefaultTimeout(60_000);
  const browsers = new Map<string, Browser>();
  for (const [name, type] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await type.launch({ headless: true }));
    } catch {
      console.warn(`markdown-padding-select: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("markdown padding selection", () => test("no engine", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    const deadline = Date.now() + 40_000;
    for (const url of [`/gallery/${ENTRY_PATH}`, "/gallery/src/pages/markdown/main.tsx"])
      if ((await warmViteServer(vite, url, { timeoutMs: Math.max(1, deadline - Date.now()) })) === 0)
        throw new Error(`warmViteServer: ${url} imports nothing; is it served?`);
  }, 60_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, variant = "selection"): Promise<Page> => {
    const context = await browsers.get(engine)!.newContext({ viewport: { width: 1400, height: 900 } });
    const page = await context.newPage();
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 1; ; attempt++) {
      await page.goto(
        `http://127.0.0.1:${port}/gallery/frame.html?entry=pages.markdown&entryPath=${ENTRY_PATH}&variant=${variant}`,
      );
      try {
        await page.waitForSelector(".md-prose p", { timeout: 30_000 });
        break;
      } catch (error) {
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    // The page's text in its own font before any point is read: in 5 of 8 WebKit opens the fonts
    // were still loading here, and a line read before Inter swapped in moved under the press (the
    // right-gutter drag and the Shift-click selected another line or nothing, CI's WebKit).
    await page.evaluate(() => document.fonts.ready);
    await rest(page);
    return page;
  };

  const rest = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  /** The viewport point of character `offset` of the first text node holding `needle`. */
  const at = (page: Page, needle: string, offset = 0) =>
    page.evaluate(
      ([needle, offset]) => {
        const walker = document.createTreeWalker(document.querySelector(".md-prose")!, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const index = node.textContent!.indexOf(needle as string);
          if (index < 0) continue;
          const range = document.createRange();
          range.setStart(node, index + (offset as number));
          range.setEnd(node, index + (offset as number) + 1);
          const box = range.getBoundingClientRect();
          return { x: box.left + 1, y: box.top + box.height / 2 };
        }
        throw new Error(`no text "${needle}"`);
      },
      [needle, offset] as const,
    );

  /** The boxes the press lands in: the editable element and the reading column around it. */
  const boxes = (page: Page) =>
    page.evaluate(() => {
      const box = (selector: string) => {
        const r = document.querySelector(selector)!.getBoundingClientRect();
        return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
      };
      return { prose: box(".md-prose"), doc: box(".md-doc"), scroll: box(".md-scroll") };
    });

  const selected = (page: Page) => page.evaluate(() => window.getSelection()!.toString());

  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2, { steps: 6 });
    await page.mouse.move(to.x, to.y, { steps: 6 });
    await page.mouse.up();
    await rest(page);
  };

  for (const engine of browsers.keys())
    describe(`markdown padding selection (${engine})`, () => {
      test("a drag from the column's left padding selects from the line's start", async () => {
        const page = await open(engine);
        const { prose, doc } = await boxes(page);
        const line = await at(page, "First paragraph");
        // In the column's own padding, between its edge and the text.
        await drag(page, { x: (doc.left + prose.left) / 2, y: line.y }, await at(page, "bold words", 4));
        expect(await selected(page)).toBe("First paragraph with a docs link and bold");
        await page.context().close();
      });

      test("a drag from the gutter outside the column selects from the line's start", async () => {
        const page = await open(engine);
        const { doc, scroll } = await boxes(page);
        expect(doc.left - scroll.left).toBeGreaterThan(40);
        const line = await at(page, "Second paragraph");
        await drag(page, { x: scroll.left + 10, y: line.y }, await at(page, "highlighted", 11));
        expect(await selected(page)).toBe("Second paragraph with highlighted");
        await page.context().close();
      });

      test("a drag from the right gutter selects from the line's end", async () => {
        const page = await open(engine);
        const { scroll } = await boxes(page);
        const line = await at(page, "Last paragraph");
        await drag(page, { x: scroll.right - 30, y: line.y }, await at(page, "the guide", 4));
        expect(await selected(page)).toBe("guide.");
        await page.context().close();
      });

      test("a drag from below the last block selects up from the document's end", async () => {
        const page = await open(engine);
        const { prose, doc } = await boxes(page);
        expect(doc.bottom - prose.bottom).toBeGreaterThan(20);
        await drag(page, { x: (prose.left + prose.right) / 2, y: prose.bottom + 12 }, await at(page, "Last paragraph"));
        expect(await selected(page)).toBe("Last paragraph ends the guide.");
        await page.context().close();
      });

      test("a drag from the gap between two blocks, in the gutter, selects from the nearer line", async () => {
        const page = await open(engine);
        const { scroll } = await boxes(page);
        const first = await at(page, "First paragraph");
        const second = await at(page, "Second paragraph");
        // A little nearer the second paragraph's line than the first's.
        const y = first.y + (second.y - first.y) * 0.75;
        await drag(page, { x: scroll.left + 10, y }, await at(page, "Second paragraph", 6));
        expect((await selected(page)).trim()).toBe("Second");
        await page.context().close();
      });

      test("double click in the gutter selects the nearest word, triple click its block", async () => {
        const page = await open(engine);
        const { prose, doc } = await boxes(page);
        const line = await at(page, "Last paragraph");
        const gutter = { x: (doc.left + prose.left) / 2, y: line.y };
        await page.mouse.dblclick(gutter.x, gutter.y);
        await rest(page);
        expect(await selected(page)).toBe("Last");
        await page.mouse.click(gutter.x, gutter.y, { clickCount: 3 });
        await rest(page);
        expect((await selected(page)).trim()).toBe("Last paragraph ends the guide.");
        await page.context().close();
      });

      test("Shift-click in the gutter extends the selection to that line", async () => {
        const page = await open(engine);
        const { scroll } = await boxes(page);
        const start = await at(page, "Last paragraph");
        await page.mouse.click(start.x, start.y);
        await rest(page);
        const line = await at(page, "Last paragraph");
        await page.keyboard.down("Shift");
        await page.mouse.click(scroll.right - 30, line.y);
        await page.keyboard.up("Shift");
        await rest(page);
        expect(await selected(page)).toBe("Last paragraph ends the guide.");
        await page.context().close();
      });

      test("a read-only file: a drag from the gutter selects from the line's start", async () => {
        const page = await open(engine, "read-only");
        const { scroll } = await boxes(page);
        const line = await at(page, "The web client");
        await drag(page, { x: scroll.left + 10, y: line.y }, await at(page, "a small app", 7));
        expect(await selected(page)).toBe("The web client for Atlas: a small");
        await page.context().close();
      });
    });
});
