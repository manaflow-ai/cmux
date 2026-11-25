// Select-all in the Feed's diff copies the whole diff (DiffLines.tsx). Only the lines near the
// viewport are mounted; Chromium and WebKit end select-all's range in the block standing in for the
// lines below the window, so the browser's own copy stopped at the last mounted line. The page's
// copy now reads every line from the diff: what the clipboard holds after the text above the diff is
// the attachment's text, byte for byte, at 10,000 lines, and no more lines mount for it.
//
// A production build of test/browser/feed-visible-only.html (the real Feed page over the mock
// provider), as bench/cloud-feed-visible-only.bench.ts serves it.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/feed-diff-select-all-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("feed-diff-select-all-browser.test.ts", async () => {
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: Array<(typeof engines)[number]> = [];
  for (const engine of engines)
    if (await probeEngineOrSkip(`feed-diff-select-all-browser ${engine[0]}`, engine[0], engine[1])) runs.push(engine);
  if (runs.length === 0) return;
  setDefaultTimeout(300_000);

  const N = 10_000;
  const SCROLLER = ".feed-detail-scroll";
  const LINE = ".feed-detail .feed-diff-line";
  let served: BenchPage;
  beforeAll(async () => {
    // bun test sets NODE_ENV=test, and Vite would build React's development JSX into the page.
    const env = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    try {
      served = await serveBenchPage("/test/browser/feed-visible-only.html", { dev: false });
    } finally {
      process.env.NODE_ENV = env;
    }
  });
  afterAll(async () => {
    await served?.close();
  });

  /** What the clipboard holds after a copy of the page's selection. */
  async function copied(page: Page, engine: string): Promise<string> {
    if (engine === "chromium") {
      await page.evaluate(() => navigator.clipboard.writeText(""));
      await page.keyboard.press("Control+c");
      return page.evaluate(() => navigator.clipboard.readText());
    }
    // WebKit headless gives no clipboard read: copy, then paste into a field of the page's own.
    await page.evaluate(() => document.execCommand("copy"));
    await page.evaluate(() => {
      const area = document.createElement("textarea");
      area.id = "paste-here";
      area.style.cssText = "position:fixed;top:0;left:0;width:10px;height:10px";
      document.body.append(area);
      area.focus();
    });
    await page.keyboard.press("Control+v");
    return page.evaluate(() => {
      const area = document.getElementById("paste-here") as HTMLTextAreaElement;
      const text = area.value;
      area.remove();
      return text;
    });
  }

  for (const [engine, type] of runs)
    test(`${engine}: select-all copies the whole diff of 10,000 lines, at the top, scrolled halfway and at the last line`, async () => {
      const browser: Browser = await type.launch({ headless: true });
      try {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        if (engine === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
        const page = await context.newPage();
        await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}` });
        await requireProductionReact(page, { dev: served.dev });
        await page.waitForFunction(() => window.benchReady === true);
        const diff = await page.evaluate(() => window.benchDiffText);
        expect(diff.split("\n").length).toBe(N);

        for (const share of [0, 0.5]) {
          await page.evaluate(
            ({ scroller, share }) => {
              const pane = document.querySelector<HTMLElement>(scroller)!;
              pane.scrollTop = (pane.scrollHeight - pane.clientHeight) * share;
              document.getSelection()!.removeAllRanges();
            },
            { scroller: SCROLLER, share },
          );
          // The window follows the scroll: its first mounted line is past the top when scrolled.
          await page.waitForFunction(
            ({ line, share }) => {
              const first = document.querySelector<HTMLElement>(line);
              return !!first && (share === 0 ? first.dataset.index === "0" : Number(first.dataset.index) > 1_000);
            },
            { line: LINE, share },
          );
          const mounted = await page.locator(LINE).count();
          expect(mounted).toBeLessThan(400);
          // Select-all, as Ctrl+A in the pane (Chromium) or the Edit menu runs it (WebKit headless binds
          // no key to it here).
          if (engine === "chromium") {
            const box = (await page.locator(SCROLLER).boundingBox())!;
            await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
            await page.keyboard.press("Control+a");
          } else await page.evaluate(() => document.execCommand("selectAll"));
          const endsInBlock = () =>
            page.evaluate(() => {
              const range = document.getSelection()!.getRangeAt(0);
              return (range.endContainer as HTMLElement).dataset?.gap !== undefined;
            });
          expect(await endsInBlock()).toBe(true);
          // Then a scroll of a few viewports: other lines mount, and the selection still ends below them.
          const before = await page.locator(LINE).first().getAttribute("data-index");
          await page.evaluate(
            (scroller) => (document.querySelector<HTMLElement>(scroller)!.scrollTop += 2_400),
            SCROLLER,
          );
          await page.waitForFunction(
            ({ line, before }) => document.querySelector<HTMLElement>(line)?.dataset.index !== before,
            { line: LINE, before },
          );
          expect(await endsInBlock()).toBe(true);

          const text = await copied(page, engine);
          // The text above the diff (its title and header), then every line of the diff.
          const at = text.indexOf(diff.slice(0, 40));
          expect(at).toBeGreaterThan(0);
          expect(text.slice(at).length).toBe(diff.length);
          expect(text.slice(at) === diff).toBe(true);
          // No line mounted for the copy: the window's own lines alone.
          expect(await page.locator(LINE).count()).toBeLessThan(400);
        }
        // Scrolled to the last line: the block below the lines has no height left, and the
        // selection still ends in it.
        await page.evaluate((scroller) => {
          const pane = document.querySelector<HTMLElement>(scroller)!;
          pane.scrollTop = pane.scrollHeight;
        }, SCROLLER);
        await page.waitForFunction((line) => !!document.querySelector(`${line}[data-index="${9_999}"]`), LINE);
        const last = await copied(page, engine);
        expect(last.slice(last.indexOf(diff.slice(0, 40))) === diff).toBe(true);
      } finally {
        await browser.close();
      }
    });

  // An empty line shows a space so it keeps its height; select-all copies the attachment's text, not
  // that space: a diff that ends in a line end, with an empty line and lines of only spaces and tabs.
  for (const [engine, type] of runs)
    test(`${engine}: select-all copies a diff that ends in a line end, with empty and blank lines, byte for byte`, async () => {
      const browser: Browser = await type.launch({ headless: true });
      try {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        if (engine === "chromium") await context.grantPermissions(["clipboard-read", "clipboard-write"]);
        const page = await context.newPage();
        await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}&blank=1` });
        await requireProductionReact(page, { dev: served.dev });
        await page.waitForFunction(() => window.benchReady === true);
        const diff = await page.evaluate(() => window.benchDiffText);
        expect(diff.endsWith("\n")).toBe(true);
        expect(diff.split("\n")).toContain("");
        expect(diff.split("\n")).toContain(" \t ");
        if (engine === "chromium") {
          const box = (await page.locator(SCROLLER).boundingBox())!;
          await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
          await page.keyboard.press("Control+a");
        } else await page.evaluate(() => document.execCommand("selectAll"));
        const text = await copied(page, engine);
        const copiedDiff = text.slice(text.indexOf(diff.slice(0, 40)));
        expect(copiedDiff.length).toBe(diff.length);
        expect(JSON.stringify(copiedDiff.slice(-8))).toBe(JSON.stringify(diff.slice(-8)));
        expect(copiedDiff === diff).toBe(true);
      } finally {
        await browser.close();
      }
    });
});
