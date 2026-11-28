// cmux-web-test-timeout: 300
// ui/Listbox keys its rows by the caller's getKey and its spacers by their place: a caller whose
// keys look like a spacer's ("space-1") must still get every row once, in order, with no blank
// area, wherever the list is scrolled and the highlighted row is kept mounted away from the view.
// Measured on a production build in Chromium (test/support/visibleLists.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-listbox-keys.browser.test.ts", async () => {
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

  /** The mounted rows' places in the list, in DOM order, and the points in view no row covers. */
  const mounted = (page: Page) =>
    page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const options = [...scroller.querySelectorAll<HTMLElement>("[role='option']")];
      const places = options.map((row) => Number(row.getAttribute("aria-posinset")));
      const view = scroller.getBoundingClientRect();
      const rects = options.map((row) => row.getBoundingClientRect());
      const blanks: number[] = [];
      for (let y = Math.ceil(view.top) + 1; y < view.top + scroller.clientHeight - 1; y += 4)
        if (!rects.some((rect) => rect.top - 0.5 <= y && y <= rect.bottom + 0.5)) blanks.push(Math.round(y - view.top));
      return { places, blanks };
    });

  test("rows keyed like the list's spacers mount once each, in order, with no blank area", async () => {
    const open = await server.open("listbox&spacerKeys=1", 1000);
    const { page } = open;
    await page.evaluate(() =>
      (window as unknown as { __visibleListControls: { scroller(): HTMLElement } }).__visibleListControls
        .scroller()
        .focus(),
    );
    // The highlight on row 2 ("space-1"), kept mounted while the view is far below it: the list
    // then has a spacer before it and one before the rows in view.
    await page.keyboard.press("ArrowDown");
    for (const fraction of [0.5, 0.2, 0.9, 0]) {
      await page.evaluate((fraction) => {
        const scroller = (
          window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
        ).__visibleListControls.scroller();
        scroller.scrollTop = (scroller.scrollHeight - scroller.clientHeight) * fraction;
      }, fraction);
      await nextFrames(page);
      const { places, blanks } = await mounted(page);
      expect({ fraction, duplicates: places.length - new Set(places).size }).toEqual({ fraction, duplicates: 0 });
      expect({ fraction, ordered: places.every((place, index) => index === 0 || place > places[index - 1]!) }).toEqual({
        fraction,
        ordered: true,
      });
      expect({ fraction, highlighted: places.includes(2) }).toEqual({ fraction, highlighted: true });
      expect({ fraction, blanks }).toEqual({ fraction, blanks: [] });
    }
    await open.close();
  });
});
