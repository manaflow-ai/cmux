// cmux-web-test-timeout: 300
// ui/Listbox keeps a row's drawn content while its item and the callback that draws it hold, and
// lays out the rows it has not mounted at an estimate. Two ways those went stale:
//   - a row moved to a new place whose callback draws the place (a number, a shortcut hint) kept
//     its old place;
//   - after an interface scale change the rows not mounted kept their old height (the estimate and
//     the heights measured before), so the list's length stayed wrong until each was scrolled to.
// Measured on a production build in Chromium (test/support/visibleLists.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-listbox-stale.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  const nextFrames = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  /** Each mounted row's place in the list and the place it draws. */
  const drawnPlaces = (page: Page) =>
    page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      return [...scroller.querySelectorAll<HTMLElement>("[role='option']")].map((row) => ({
        place: Number(row.getAttribute("aria-posinset")),
        drawn: Number(/^(\d+)\./.exec(row.textContent ?? "")?.[1]),
      }));
    });

  test("a row moved to a new place draws its new place", async () => {
    const open = await server.open("listbox&numbered=1", 1000);
    const { page } = open;
    const before = await drawnPlaces(page);
    expect(before.length).toBeGreaterThan(5);
    expect(before.filter((row) => row.drawn !== row.place)).toEqual([]);
    // The fifth row to the top: rows one to five each move one place.
    await page.evaluate(() => (window as unknown as { __reorder(): void }).__reorder());
    await nextFrames(page);
    const after = await drawnPlaces(page);
    expect(after.filter((row) => row.drawn !== row.place)).toEqual([]);
    expect(
      await page.evaluate(() =>
        (window as unknown as { __visibleListControls: { scroller(): HTMLElement } }).__visibleListControls
          .scroller()
          .querySelector("[role='option']")
          ?.textContent?.startsWith("1. item 00004"),
      ),
    ).toBe(true);
    await open.close();
  });

  /** The list's scroll length and what its rows lay out to, every row at the mounted rows' height. */
  const lengths = (page: Page, n: number) =>
    page.evaluate((n) => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const row = scroller.querySelector<HTMLElement>("[role='option']")!;
      return { length: scroller.scrollHeight, rows: row.getBoundingClientRect().height * n };
    }, n);

  for (const visited of [false, true])
    test(`300 rows at interface scale 1 -> 1.25: the list's length follows without visiting the rows${visited ? ", some visited before" : ""}`, async () => {
      const open = await server.open("listbox&scale=1", 300);
      const { page } = open;
      const scroll = (fraction: number) =>
        page.evaluate((fraction) => {
          const scroller = (
            window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
          ).__visibleListControls.scroller();
          scroller.scrollTop = (scroller.scrollHeight - scroller.clientHeight) * fraction;
        }, fraction);
      // Rows down the list measured, then left: their heights are cached from scale 1.
      if (visited)
        for (const fraction of [0.3, 0.6, 0]) {
          await scroll(fraction);
          await nextFrames(page);
        }
      const at1 = await lengths(page, 300);
      expect(Math.abs(at1.length - at1.rows)).toBeLessThanOrEqual(1);
      await page.evaluate(() => (window as unknown as { __setScale(scale: string): void }).__setScale("1.25"));
      await nextFrames(page);
      await nextFrames(page);
      const at125 = await lengths(page, 300);
      expect(at125.rows).toBeCloseTo(at1.rows * 1.25, 0);
      expect({ length: at125.length, off: Math.abs(at125.length - at125.rows) <= 1 }).toEqual({
        length: at125.length,
        off: true,
      });
      await open.close();
    });
});
