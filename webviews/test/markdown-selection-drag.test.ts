// Text selection in the markdown page with a real pointer (MARKDOWN-SELECTION, user 2026-10-20: "I do
// highlight stuff in Markdown and it's buggy in general"). The real page (gallery entry
// pages.markdown, variant selection) in Chromium and WebKit:
//
// - a drag across a ==highlight== and $math$ keeps the text where it is: the syntax stays hidden
//   (before, every marker the selection touched appeared mid-drag and the math turned back into its
//   source, so the words under the pointer moved about 50 px and the selection ended elsewhere);
// - Cmd-A selects the document without revealing any syntax;
// - a drag that starts in a table cell and leaves the table selects text up to the pointer (before,
//   it stayed a one-cell selection for the rest of the drag);
// - a reload from disk (the file changed) keeps the selection on the same words;
// - double click selects a word, triple click a block, and copy writes the selection as Markdown.
//
// The app draws the page in WebKit; the same bugs showed in Chromium, so both run. An engine that is
// not installed is skipped.
//
// Every page loads the markdown entry alone (`entryPath`, src/gallery/registry.ts). Without it each
// of the 16 pages, in a fresh context, loaded all ~150 gallery entries (about 2,300 modules), and
// the warm-up transformed them all first: beside seven other dev server files on the CI runner the
// file took about 113 s of its 120 s (run 39554271195), and the next run was killed in its last
// test (job 119068678028), with nothing stuck.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("markdown-selection-drag.test.ts", async () => {
  const ENTRY_PATH = "src/pages/markdown/markdown.gallery.ts";
  // Half the runner's limit per file (scripts/ci/run-webviews-tests.sh): a stuck step fails as its
  // own test, by name, instead of the runner killing the file with no failure in its log.
  setDefaultTimeout(60_000);
  // The probe's browser is the one the tests use: a launch takes seconds on a loaded runner.
  const browsers = new Map<string, Browser>();
  for (const [name, type] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await type.launch({ headless: true }));
    } catch {
      console.warn(`markdown-selection-drag: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("markdown selection", () => test("no engine", () => {}));
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
    // The entry and the page it mounts (pages/markdown/main.tsx), not the frame: its registry names
    // every entry. Module URLs carry the config's base, /gallery/; a path outside it is a 404 that
    // warms nothing, so a warm-up that found no imports fails here. Both share one budget that ends
    // inside this hook's limit, so a slow warm-up reports its own error, not a hook timeout.
    const deadline = Date.now() + 40_000;
    for (const url of [`/gallery/${ENTRY_PATH}`, "/gallery/src/pages/markdown/main.tsx"])
      if ((await warmViteServer(vite, url, { timeoutMs: Math.max(1, deadline - Date.now()) })) === 0)
        throw new Error(`warmViteServer: ${url} imports nothing; is it served?`);
  }, 60_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const FILE = "/Users/you/src/atlas-web/SELECTION.md";

  const open = async (engine: string): Promise<Page> => {
    const context = await browsers.get(engine)!.newContext({ viewport: { width: 800, height: 900 } });
    const page = await context.newPage();
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 1; ; attempt++) {
      await page.goto(
        `http://127.0.0.1:${port}/gallery/frame.html?entry=pages.markdown&entryPath=${ENTRY_PATH}&variant=selection`,
      );
      try {
        // KaTeX loads with the first equation: the inline formula is drawn once it is in.
        await page.waitForSelector(".md-prose .md-math-inline", { timeout: 30_000 });
        break;
      } catch (error) {
        // Vite's dependency optimizer can reload the first page while it compiles.
        if (attempt === 3 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await rest(page);
    return page;
  };

  /** Two frames: decorations and the selection have been drawn. */
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

  const selected = (page: Page) => page.evaluate(() => window.getSelection()!.toString());
  const revealed = (page: Page) => page.evaluate(() => document.querySelectorAll(".md-prose .md-syntax").length);

  /** A click on the last paragraph: a caret far from every other block. */
  const park = async (page: Page) => {
    const point = await at(page, "Last paragraph", 2);
    await page.mouse.click(point.x, point.y);
    await rest(page);
  };

  /** Presses the button at `from`, moves to `to` in steps, and returns before the release. */
  const press = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2, { steps: 6 });
    await page.mouse.move(to.x, to.y, { steps: 6 });
    await rest(page);
  };

  for (const engine of browsers.keys())
    describe(`markdown selection (${engine})`, () => {
      test("a drag across a highlight and inline math keeps the text under the pointer in place", async () => {
        const page = await open(engine);
        await park(page);
        const before = await at(page, "inline.");
        await press(page, await at(page, "First paragraph"), await at(page, "inline.", 3));
        const during = await at(page, "inline.");
        expect(await revealed(page)).toBe(0);
        expect(await page.locator(".md-prose .md-math-inline").count()).toBe(1);
        await page.mouse.up();
        await rest(page);
        expect(Math.abs(during.x - before.x)).toBeLessThan(1);
        const text = await selected(page);
        expect(text.startsWith("First paragraph")).toBe(true);
        expect(text).toMatch(/inl$/);
        // Releasing the button changes nothing either: the selection is not inside a highlight.
        expect(await revealed(page)).toBe(0);
        expect(Math.abs((await at(page, "inline.")).x - before.x)).toBeLessThan(1);
        await page.context().close();
      });

      test("Cmd-A selects the document and reveals no syntax", async () => {
        const page = await open(engine);
        await park(page);
        // Cmd-A on the Mac; on the Linux runners ProseMirror's Select All is Ctrl-A.
        await page.keyboard.press("ControlOrMeta+a");
        await rest(page);
        expect(await revealed(page)).toBe(0);
        expect(await page.locator(".md-prose .md-math-inline").count()).toBe(1);
        const text = await selected(page);
        expect(text).toContain("Selection guide");
        expect(text).toContain("Last paragraph ends the guide.");
        await page.context().close();
      });

      test("a caret placed in a highlight still reveals its markers once the button is up", async () => {
        const page = await open(engine);
        await park(page);
        const word = await at(page, "highlighted", 3);
        await page.mouse.click(word.x, word.y);
        await rest(page);
        expect(await revealed(page)).toBe(2);
        await page.context().close();
      });

      test("a drag from a table cell out of the table selects text up to the pointer", async () => {
        const page = await open(engine);
        await park(page);
        await press(page, await at(page, "Ada", 1), await at(page, "answer", 2));
        await page.mouse.up();
        await rest(page);
        expect(await page.locator(".md-prose .selectedCell").count()).toBe(0);
        const text = await selected(page);
        expect(text).toContain("da");
        expect(text).toContain("Engineer");
        expect(text).toContain("const an");
        await page.context().close();
      });

      test("a drag inside a table still selects whole cells", async () => {
        const page = await open(engine);
        await park(page);
        await press(page, await at(page, "Name", 1), await at(page, "Engineer", 3));
        await page.mouse.up();
        expect(await page.locator(".md-prose .selectedCell").count()).toBe(4);
        await page.context().close();
      });

      test("a reload from disk keeps the selection on the same words", async () => {
        const page = await open(engine);
        await park(page);
        await press(page, await at(page, "Last paragraph"), await at(page, "paragraph ends", 9));
        await page.mouse.up();
        expect(await selected(page)).toBe("Last paragraph");
        // Another program rewrote the first paragraph; the selected one did not change.
        await page.evaluate((file) => {
          const host = (window as unknown as { __mockHost: { emit(stream: string, data: unknown): void } }).__mockHost;
          host.emit("cmux.markdown.changes", {
            path: file,
            hash: "h-reloaded",
            text: "# Selection guide\n\nFirst paragraph, rewritten by another program.\n\nLast paragraph ends the guide.\n",
          });
        }, FILE);
        await page.waitForFunction(() => document.querySelector(".md-prose")!.textContent!.includes("rewritten"));
        await rest(page);
        expect(await selected(page)).toBe("Last paragraph");
        await page.context().close();
      });

      test("double click selects a word, triple click a block", async () => {
        const page = await open(engine);
        await park(page);
        const bold = await at(page, "bold words", 2);
        await page.mouse.dblclick(bold.x, bold.y);
        expect(await selected(page)).toBe("bold");
        const heading = await at(page, "Closing heading", 3);
        await page.mouse.click(heading.x, heading.y, { clickCount: 3 });
        expect((await selected(page)).trim()).toBe("Closing heading");
        const code = await at(page, "answer", 1);
        await page.mouse.click(code.x, code.y, { clickCount: 3 });
        expect((await selected(page)).trim()).toBe("const answer = 42;");
        await page.context().close();
      });

      test("copying a drag selection writes its Markdown", async () => {
        const page = await open(engine);
        await park(page);
        await press(page, await at(page, "First paragraph"), await at(page, "Second list item", 6));
        await page.mouse.up();
        const copied = await page.evaluate(() => {
          let plain = "";
          document.addEventListener("copy", (event) => void (plain = event.clipboardData!.getData("text/plain")), {
            once: true,
          });
          document.execCommand("copy");
          return plain;
        });
        expect(copied).toBe(
          "First paragraph with a [docs link](https://example.com/docs) and **bold words** in it.\n\n" +
            "Second paragraph with ==highlighted words== and the formula $E = mc^2$ inline.\n\n" +
            "- First list item\n- Second\n",
        );
        await page.context().close();
      });
    });
});
