// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The row the reader focused stays the transcript's tab stop when an older page lands above it. The
// page draws the chat's first date line again (rows[0] taken out, the page and a new date line in its
// place), and the presence hints (conversation/rowPresence.ts) still held the index of the row the tab
// stop was on before the reader focused another, with no rows changing between: that stale hint was
// read as the focused row taken out, and the tab stop went to the first row of the chat.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { godLog } from "../bench/godFixture";
import { papercutPane, type PapercutStep } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-older-page-tab-stop.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-older-page-tab-stop: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("transcript older page tab stop", () => test("no engine", () => {}));
    return;
  }

  const log = godLog("small", { turns: 300 });
  const lead: PapercutStep[] = log.events.map((event) => [
    event.dir,
    event.kind,
    event.msg as Record<string, unknown>,
    event.at,
  ]);

  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
  });

  /// Resolves after `count` painted frames.
  const frames = (page: Page, count: number) =>
    page.evaluate(
      (count) =>
        new Promise<void>((resolve) => {
          let left = count;
          window.cmuxAfterPaint(() => {
            left -= 1;
            if (left > 0) return true;
            resolve();
            return false;
          });
        }),
      count,
    );

  for (const [name] of engines)
    test(`${name}: a focused row keeps the tab stop when an older page lands above it`, async () => {
      const pane = await papercutPane(() => browsers.get(name)!, {
        turns: 1,
        running: false,
        lead,
        attachPage: 160,
        daemonIndexes: true,
      });
      try {
        const page = await pane.open({ width: 1000, height: 800 });
        // A row in the middle of the view, not the first on screen: the tab stop falls to the first row on
        // screen when the one asked for is not drawn.
        const focused = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const box = scroller.getBoundingClientRect();
          const middle = box.top + box.height / 2;
          const row = [...document.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")].find((each) => {
            const rect = each.getBoundingClientRect();
            return rect.top > box.top + 40 && rect.top < middle && rect.bottom < box.bottom;
          })!;
          row.focus();
          return { id: row.dataset.rowId!, fromBottom: scroller.scrollHeight - scroller.scrollTop };
        });
        const stop = () =>
          page.evaluate(
            () => document.querySelector<HTMLElement>('.acpmux-row[data-row-id][tabindex="0"]')?.dataset.rowId,
          );
        await page.waitForFunction(
          (id) => document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)?.tabIndex === 0,
          focused.id,
        );
        expect(await stop()).toBe(focused.id);
        // Up to the top of the loaded rows until an older page lands above them.
        const firstRow = () =>
          page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-row[data-row-id]")?.dataset.rowId);
        const pages = () => pane.methods.filter((method) => method === "_acpmux/events").length;
        const pagesBefore = pages();
        const topBefore = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          return scroller.scrollHeight;
        });
        for (let step = 0; step < 400; step++) {
          await page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            scroller.scrollTop = Math.max(0, scroller.scrollTop - 600);
          });
          await frames(page, 1);
          if (
            pages() > pagesBefore &&
            (await page.evaluate(() => document.querySelector(".acpmux-scroll")!.scrollHeight)) > topBefore
          )
            break;
        }
        expect(pages()).toBeGreaterThan(pagesBefore);
        await frames(page, 3);
        // Back to the focused row, in the middle of the view again (the page grew the content above it).
        await page.evaluate((fromBottom) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = scroller.scrollHeight - fromBottom;
        }, focused.fromBottom);
        await page.waitForFunction(
          (id) => document.querySelector(`.acpmux-row[data-row-id="${id}"]`) !== null,
          focused.id,
        );
        await frames(page, 3);
        const after = { stop: await stop(), first: await firstRow() };
        console.log(
          `transcript-older-page-tab-stop ${name}: ${JSON.stringify({ focused: focused.id, ...after, pages: pages() - pagesBefore })}`,
        );
        expect(after.stop).toBe(focused.id);
      } finally {
        await pane.close();
      }
    });
});
