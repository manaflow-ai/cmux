// cmux-web-test-timeout: 300
// A filter's first result comes into view (review of #46204): typing puts the highlight back on
// row 0 without changing its index, and a list the user had scrolled kept the new first result
// out of view. ui/VirtualList now scrolls to the active row when its row (its React key) changes,
// and never on the user's own scrolling. Each list opens with 1,000 items in a
// production build in Chromium (test/support/visibleLists.ts), is scrolled well down by hand (it
// must stay there), takes a filter whose first result was out of view, and one frame later:
// - the first result is mounted, inside the scroller's visible rect, and named by the field's
//   aria-activedescendant;
// - a scroll by hand with no filter change stays where the user put it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import type { VisibleListOpen, VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-filter-scroll.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { startVisibleLists } = await import("./support/visibleLists");
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  }, 240_000);
  afterAll(async () => {
    await server?.stop();
  });

  // `first` is a text the filter's first result holds (each list sorts its own way).
  const cases = [
    { name: "branch-base-picker", filter: "9", first: "item 0123 00090" },
    { name: "jump-to-file", filter: "9", first: "item 0123 00009" },
    { name: "virtual-list-filter", filter: "9", first: "item 00009" },
  ];

  type Controls = { scroller(): HTMLElement; filter(): HTMLElement };

  /** Scroll the list by hand: `to` "end" or a pixel delta. Returns scrollTop, and two frames later. */
  const scrollBy = (open: VisibleListOpen, to: "end" | number) =>
    open.page.evaluate(async (to) => {
      const scroller = (window as unknown as { __visibleListControls: Controls }).__visibleListControls.scroller();
      if (to === "end") scroller.scrollTop = scroller.scrollHeight;
      else scroller.scrollTop += to;
      scroller.dispatchEvent(new Event("scroll"));
      const settled = scroller.scrollTop;
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      return { settled, after: scroller.scrollTop };
    }, to);

  /** The active row as the field names it, after one frame. */
  const activeRow = (open: VisibleListOpen) =>
    open.page.evaluate(async () => {
      await new Promise((done) => requestAnimationFrame(done));
      const controls = (window as unknown as { __visibleListControls: Controls }).__visibleListControls;
      const scroller = controls.scroller();
      const id = controls.filter().getAttribute("aria-activedescendant");
      const row = id ? document.getElementById(id) : null;
      const view = scroller.getBoundingClientRect();
      const rect = row?.getBoundingClientRect();
      return {
        id,
        mounted: Boolean(row && scroller.contains(row)),
        text: row?.textContent ?? "",
        inView: Boolean(rect && rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5),
        scrollTop: scroller.scrollTop,
        rowTop: rect ? Math.round(rect.top - view.top) : null,
      };
    });

  for (const { name, filter, first } of cases) {
    test(`${name}: a filter's first result comes into view, and a scroll by hand stays put`, async () => {
      const open = await server.open(name, 1000);
      try {
        // Scroll well down by hand: the list stays there (it does not jump back to the highlight).
        const down = await scrollBy(open, "end");
        expect(down.settled).toBeGreaterThan(300);
        // Rows measured on the way may grow the list under it (measureRows); it never moves back up.
        expect(down.after).toBeGreaterThanOrEqual(down.settled - 1);
        expect((await activeRow(open)).inView).toBe(false);

        await open.page.evaluate(() =>
          (window as unknown as { __visibleListControls: Controls }).__visibleListControls.filter().focus(),
        );
        await open.page.keyboard.type(filter);
        const typed = await activeRow(open);
        console.log(`lane-VM ${name}: after typing "${filter}": ${JSON.stringify(typed)}`);
        expect(typed.text).toContain(first);
        expect(typed.mounted).toBe(true);
        expect(typed.inView).toBe(true);

        // A scroll by hand with no filter change: the list stays where the user put it.
        const again = await scrollBy(open, 400);
        expect(again.settled).toBeGreaterThan(typed.scrollTop);
        expect(again.after).toBeGreaterThanOrEqual(again.settled - 1);
        const after = await activeRow(open);
        expect(after.scrollTop).toBeGreaterThanOrEqual(again.settled - 1);
        expect(after.inView).toBe(false);
      } finally {
        await open.close();
      }
    });
  }
});
