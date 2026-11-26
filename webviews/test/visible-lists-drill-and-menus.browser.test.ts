// cmux-web-test-timeout: 300
// The pickers draw the visible area and re-render only the rows that changed, whatever the list's
// length (Leo 2026-11-18: "we draw the visible area, right? ... we need to be able to guard against
// that"). Measured on a production build in Chromium (test/support/visibleLists.ts):
// - ui/DrillList (the path picker), New Message's recipient field and the new tab's slash menu at
//   100, 1,000 and 10,000 items mount at most the viewport's rows plus one viewport each side plus
//   the highlighted row, the same at 1,000 and 10,000 (within 10%);
// - the mention menu and the file search are capped (78 rows from mentionItems.ts's parts, and
//   FILE_SEARCH_LIMIT), so they are measured at the cap and may mount it;
// - a hover re-renders at most the two rows it moved between (and at least one: the count sees the
//   rows), one scroll step at most the rows that came in, one changed item only its row, a key at
//   most the mounted rows;
// - DrillList's arrows, Home/End and Return reach rows that were not mounted, the active
//   descendant names a mounted row in view with its place in the whole list, and the level's
//   section heading and its `after` line stay while it is windowed.
// The main-thread times per step are printed, not asserted.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-drill-and-menus.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  // Each case's list is 320 px of 28 px rows, but the recipient field's (its own CSS: up to nine
  // 44 px rows, and four rows of overscan each side).
  const cases: {
    name: string;
    lengths: number[];
    /** Most rows mounted at any length. */
    mountedBound: number;
    /** Windowed: the mounted rows match across lengths. */
    windowed: boolean;
    changeOneBound?: number;
  }[] = [
    { name: "drill-list", lengths: [100, 1000, 10000], mountedBound: Math.ceil(320 / 28) * 3 + 2, windowed: true },
    { name: "slash-menu", lengths: [100, 1000, 10000], mountedBound: Math.ceil(320 / 28) * 3 + 2, windowed: true },
    { name: "mention-menu", lengths: [78], mountedBound: 78, windowed: false },
    { name: "file-search", lengths: [50], mountedBound: 50, windowed: false },
  ];

  for (const { name, lengths, mountedBound, windowed, changeOneBound = 1 } of cases) {
    describe(name, () => {
      test("mounts only the visible rows, and steps re-render only the rows they touch", async () => {
        const mounted = new Map<number, number>();
        for (const n of lengths) {
          const open = await server.open(name, n);
          const { rows, domNodes } = await open.counts();
          mounted.set(n, rows);
          expect(rows).toBeLessThanOrEqual(mountedBound);
          const has = await open.page.evaluate(() => {
            const controls = (window as unknown as { __visibleListControls: Record<string, unknown> })
              .__visibleListControls;
            return { filter: !!controls.filter, changeOne: !!controls.changeOne };
          });
          const report: string[] = [`rows ${rows}`, `nodes ${domNodes}`];
          // First, while the changed row (the third) is mounted.
          if (has.changeOne) {
            const change = await open.measure("changeOne");
            expect(change.rowRendersMax).toBeLessThanOrEqual(changeOneBound);
            expect(change.rowRendersMax).toBeGreaterThanOrEqual(1);
            report.push(`change ${change.rowRendersMax} rows ${change.taskMsP95} ms`);
          }
          const scroll = await open.measure("scroll");
          expect(scroll.rowRendersMax).toBeLessThanOrEqual(3);
          report.push(`scroll ${scroll.rowRendersMax} rows ${scroll.taskMsP95} ms`);
          const hover = await open.measure("hover");
          expect(hover.rowRendersMax).toBeLessThanOrEqual(2);
          expect(hover.rowRendersMax).toBeGreaterThanOrEqual(1);
          report.push(`hover ${hover.rowRendersMax} rows ${hover.taskMsP95} ms`);
          const resize = await open.measure("resize");
          expect(resize.rowRendersMax).toBeLessThanOrEqual(rows);
          report.push(`resize ${resize.rowRendersMax} rows ${resize.taskMsP95} ms`);
          await open.close();
          if (has.filter) {
            // A fresh page: the steps above moved its scroll and pointer.
            const typing = await server.open(name, n);
            const type = await typing.measure("type");
            expect(type.rowRendersMax).toBeLessThanOrEqual(mountedBound);
            report.push(`key ${type.rowRendersMax} rows ${type.taskMsP95} ms p95`);
            await typing.close();
          }
          console.log(`${name} at ${n}: ${report.join(", ")}`);
        }
        if (windowed) {
          const [small, large] = [mounted.get(1000)!, mounted.get(10000)!];
          expect(Math.abs(large - small)).toBeLessThanOrEqual(Math.ceil(small * 0.1));
        }
      });
    });
  }

  test("drill-list: the arrows, Home, End and Return reach rows that were not mounted; the heading and the after line stay", async () => {
    const open = await server.open("drill-list", 10000);
    const { page } = open;
    const state = () =>
      page.evaluate(() => {
        const field = document.querySelector<HTMLInputElement>("input[role='combobox']")!;
        const id = field.getAttribute("aria-activedescendant");
        const row = id ? document.getElementById(id) : null;
        const scroller = document.querySelector<HTMLElement>(".case-list")!;
        const view = scroller.getBoundingClientRect();
        const box = row?.getBoundingClientRect();
        return {
          mounted: !!row,
          inView: !!box && box.top >= view.top - 1 && box.bottom <= view.bottom + 1,
          posinset: row?.getAttribute("aria-posinset") ?? null,
          setsize: row?.getAttribute("aria-setsize") ?? null,
          selected: row?.getAttribute("aria-selected") ?? null,
        };
      });
    const heading = () =>
      page.evaluate(() => ({
        heading: document.querySelector(".ui-drill-section")?.textContent ?? null,
        after: !!document.querySelector(".case-list .case-after"),
      }));
    expect(await heading()).toEqual({ heading: "Locations", after: true });
    await page.focus("input[role='combobox']");
    // The four Locations, then the level's 10,000 rows.
    await page.keyboard.press("End");
    expect(await state()).toMatchObject({
      mounted: true,
      inView: true,
      posinset: "10004",
      setsize: "10004",
      selected: "true",
    });
    await page.keyboard.press("Home");
    expect(await state()).toMatchObject({ mounted: true, inView: true, posinset: "1" });
    for (let index = 0; index < 40; index++) await page.keyboard.press("ArrowDown");
    expect(await state()).toMatchObject({ mounted: true, inView: true, posinset: "41" });
    await page.keyboard.press("Enter");
    // Row 41 is the level's 37th (index 36).
    expect(await page.evaluate(() => (window as unknown as { __submitted: string[] }).__submitted.at(-1))).toBe(
      "id-36",
    );
    expect((await open.counts()).rows).toBeLessThanOrEqual(Math.ceil(320 / 28) * 3 + 2);
    // Scrolled to the end, the after line is drawn after the last row.
    await page.evaluate(() => {
      const list = document.querySelector<HTMLElement>(".case-list")!;
      list.scrollTop = list.scrollHeight;
    });
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const end = await page.evaluate(() => {
      const list = document.querySelector<HTMLElement>(".case-list")!;
      const rows = list.querySelectorAll("[role='option']");
      return {
        last: rows[rows.length - 1]?.getAttribute("aria-posinset") ?? null,
        after: !!list.querySelector(".case-after"),
      };
    });
    expect(end).toEqual({ last: "10004", after: true });
    await open.close();
  });
});
