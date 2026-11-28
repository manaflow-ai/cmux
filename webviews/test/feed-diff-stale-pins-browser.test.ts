// Clicks on the Feed's diff lines keep at most the caret's line mounted once released
// (DiffLines.tsx). Only the lines near the viewport mount; the lines a selection starts and ends on
// stay mounted, and a caret counts (a Shift-click extends from it). Each press used to add its line to
// the pinned ones, and only a selection change replaced them. In Chromium every press on a line (left,
// middle or right button) leaves a caret there, whose selection change clears the others, so real
// clicks never built them up; the jsdom test (feed-diff-visible-only.test.tsx) presses with no
// selection to show that. This one checks the pins the fix sets from scratch keep what real clicks
// need: after 50 clicks far apart, the window and the last caret's line, no other.
//
// A production build of test/browser/feed-visible-only.html (the real Feed page over the mock
// provider), as bench/cloud-feed-visible-only.bench.ts serves it.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/feed-diff-stale-pins-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { gotoBenchPage, requireProductionReact, serveBenchPage, type BenchPage } from "../bench/support/benchPage";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("feed-diff-stale-pins-browser.test.ts", async () => {
  const engines = [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const;
  const runs: Array<(typeof engines)[number]> = [];
  for (const engine of engines)
    if (await probeEngineOrSkip(`feed-diff-stale-pins-browser ${engine[0]}`, engine[0], engine[1])) runs.push(engine);
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

  /** Scrolls the line `index` near the pane's top and waits for it to mount and two frames to pass. */
  async function scrollTo(page: Page, index: number) {
    await page.evaluate(
      ({ scroller, line, index }) => {
        const pane = document.querySelector<HTMLElement>(scroller)!;
        const first = document.querySelector<HTMLElement>(line)!;
        pane.scrollTop = Math.max(0, (index - 2) * first.offsetHeight);
      },
      { scroller: SCROLLER, line: LINE, index },
    );
    await page.waitForFunction(({ line, index }) => !!document.querySelector(`${line}[data-index="${index}"]`), {
      line: LINE,
      index,
    });
    await settle(page);
  }
  const settle = (page: Page) =>
    page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );
  const mountedIndexes = (page: Page) =>
    page.$$eval(LINE, (rows) => rows.map((row) => Number((row as HTMLElement).dataset.index)));

  for (const [engine, type] of runs)
    test(`${engine}: 50 clicks on lines far apart leave mounted only the window and the last caret's line`, async () => {
      const browser: Browser = await type.launch({ headless: true });
      try {
        const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
        const page = await context.newPage();
        await gotoBenchPage(page, { ...served, url: `${served.url}#n=${N}` });
        await requireProductionReact(page, { dev: served.dev });
        await page.waitForFunction(() => window.benchReady === true);
        await page.evaluate(() => document.getSelection()!.removeAllRanges());
        await scrollTo(page, 9_600);
        const windowRows = (await mountedIndexes(page)).length;

        const pressed: number[] = [];
        for (let at = 0; at < 50; at++) {
          const index = at * 190 + 5;
          await scrollTo(page, index);
          const box = (await page.locator(`${LINE}[data-index="${index}"]`).boundingBox())!;
          await page.mouse.click(box.x + 20, box.y + box.height / 2);
          pressed.push(index);
        }
        // A click leaves a caret on the line it pressed.
        expect(await page.evaluate(() => document.getSelection()!.type)).toBe("Caret");
        await scrollTo(page, 9_600);
        const indexes = await mountedIndexes(page);
        const extra = indexes.filter((at) => at < 9_400);
        console.log(JSON.stringify({ engine, window: windowRows, mounted: indexes.length, extra: extra.length }));
        expect(extra).toEqual([pressed.at(-1)!]);
        expect(indexes.length).toBeLessThanOrEqual(windowRows + 1);
      } finally {
        await browser.close();
      }
    });
});
