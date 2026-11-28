// cmux-web-test-timeout: 300
// The shared list primitives draw the visible area, whatever the list's length (Leo 2026-11-18:
// "we draw the visible area, right? ... we need to be able to guard against that"). ui/Listbox
// windows itself past a menu's worth of rows; ui/VirtualList's rows keep their style object, so a
// memoized row does not re-render on a scroll step. Measured on a production build in
// Chromium (test/support/visibleLists.ts), each case at 1,000 and 10,000 items:
// - mounted rows are the same at both lengths (within 10%), at most the viewport's rows plus one
//   viewport each side plus the highlighted row;
// - a hover re-renders at most the two rows it moved between, one scroll step at most the rows that
//   came in, one changed item only its row;
// - the arrows, Home/End and Return still reach and pick rows that were not mounted, and the
//   active descendant always names a mounted row in view with its place in the whole list.
// The main-thread times per step are printed, not asserted.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-primitives.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  // The cases' lists are 320 px of 28 px rows.
  const VIEWPORT_ROWS = Math.ceil(320 / 28);
  const MOUNTED_BOUND = VIEWPORT_ROWS * 3 + 2;
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  const cases: { name: string; changeOneBound: number }[] = [
    { name: "listbox", changeOneBound: 1 },
    { name: "virtual-list", changeOneBound: 1 },
  ];

  for (const { name, changeOneBound } of cases) {
    describe(name, () => {
      test("mounts the same rows at 1,000 and 10,000 items, and steps re-render only the rows they touch", async () => {
        const mounted: number[] = [];
        for (const n of [1000, 10000]) {
          const open = await server.open(name, n);
          const { rows, domNodes } = await open.counts();
          mounted.push(rows);
          expect(rows).toBeLessThanOrEqual(MOUNTED_BOUND);
          const has = await open.page.evaluate(() => {
            const controls = (window as unknown as { __visibleListControls: Record<string, unknown> })
              .__visibleListControls;
            return { filter: !!controls.filter, changeOne: !!controls.changeOne };
          });
          const report: string[] = [`rows ${rows}`, `nodes ${domNodes}`];
          const scroll = await open.measure("scroll");
          expect(scroll.rowRendersMax).toBeLessThanOrEqual(3);
          report.push(`scroll ${scroll.rowRendersMax} rows ${scroll.taskMsP95} ms`);
          const hover = await open.measure("hover");
          expect(hover.rowRendersMax).toBeLessThanOrEqual(2);
          report.push(`hover ${hover.rowRendersMax} rows ${hover.taskMsP95} ms`);
          if (has.changeOne) {
            const change = await open.measure("changeOne");
            expect(change.rowRendersMax).toBeLessThanOrEqual(changeOneBound);
            report.push(`change ${change.rowRendersMax} rows ${change.taskMsP95} ms`);
          }
          const resize = await open.measure("resize");
          expect(resize.rowRendersMax).toBeLessThanOrEqual(rows);
          report.push(`resize ${resize.rowRendersMax} rows ${resize.taskMsP95} ms`);
          await open.close();
          if (has.filter) {
            // A fresh page: the steps above moved its scroll and pointer.
            const typing = await server.open(name, n);
            const type = await typing.measure("type");
            // A key replaces the matches: the rows of a few viewports at most, never N.
            expect(type.rowRendersMax).toBeLessThanOrEqual(VIEWPORT_ROWS * 5);
            report.push(`key ${type.rowRendersMax} rows ${type.taskMsP95} ms p95`);
            await typing.close();
          }
          console.log(`${name} at ${n}: ${report.join(", ")}`);
        }
        expect(Math.abs(mounted[1]! - mounted[0]!)).toBeLessThanOrEqual(Math.ceil(mounted[0]! * 0.1));
      });
    });
  }

  /** The active descendant of the focused field or list: its place in the list, and whether it is
   * mounted and wholly inside the scroller's view. */
  async function activeRow(page: Awaited<ReturnType<VisibleListsServer["open"]>>["page"]) {
    return page.evaluate(() => {
      const owner = document.activeElement?.closest("[aria-activedescendant]") ?? document.activeElement;
      const id = owner?.getAttribute("aria-activedescendant");
      const row = id ? document.getElementById(id) : null;
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const view = scroller.getBoundingClientRect();
      const box = row?.getBoundingClientRect();
      return {
        mounted: !!row,
        inView: !!box && box.top >= view.top - 1 && box.bottom <= view.bottom + 1,
        posinset: row?.getAttribute("aria-posinset") ?? null,
        setsize: row?.getAttribute("aria-setsize") ?? null,
        text: row?.textContent ?? null,
      };
    });
  }
  const submitted = (page: Awaited<ReturnType<VisibleListsServer["open"]>>["page"]) =>
    page.evaluate(() => (window as unknown as { __submitted: string[] }).__submitted.at(-1));

  test("listbox: the arrows, Home, End and Return reach rows that were not mounted", async () => {
    const open = await server.open("listbox", 10000);
    const { page } = open;
    await page.evaluate(() =>
      (window as unknown as { __visibleListControls: { list(): HTMLElement } }).__visibleListControls.list().focus(),
    );
    await page.keyboard.press("End");
    expect(await activeRow(page)).toMatchObject({ mounted: true, inView: true, posinset: "10000", setsize: "10000" });
    await page.keyboard.press("Home");
    expect(await activeRow(page)).toMatchObject({ mounted: true, inView: true, posinset: "1" });
    for (let index = 0; index < 40; index++) await page.keyboard.press("ArrowDown");
    expect(await activeRow(page)).toMatchObject({ mounted: true, inView: true, posinset: "41" });
    await page.keyboard.press("Enter");
    expect(await submitted(page)).toBe("id-40");
    expect((await open.counts()).rows).toBeLessThanOrEqual(MOUNTED_BOUND);
    await open.close();
  });
});
