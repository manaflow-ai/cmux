// cmux-web-test-timeout: 300
// ui/Combobox draws the visible area, whatever the list's length (Leo 2026-11-18: "we draw the
// visible area, right? ... we need to be able to guard against that"): past a menu's worth of rows
// it windows itself, with or without pinned actions. Measured on a production build in
// Chromium (test/support/visibleLists.ts), each case at 1,000 and 10,000 items:
// - mounted rows are the same at both lengths (within 10%), at most the viewport's rows plus one
//   viewport each side plus the highlighted row;
// - a hover re-renders at most the two rows it moved between, one scroll step at most the rows that
//   came in, one changed item only the mounted rows (see below);
// - the arrows and Return still reach and pick rows that were not mounted, and the
//   active descendant always names a mounted row in view with its place in the whole list;
// - with pinned actions (above or under the list, as the folder popover has them), End, Home and
//   the arrows land in view at every step with the action in its place, and the view scrolled
//   anywhere has no blank and no overlapping rows.
// The main-thread times per step are printed, not asserted.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-combobox.browser.test.ts", async () => {
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

  // Combobox suggestions are strings drawn by the caller's `renderItem(value)`: a caller whose data
  // changed hands a new renderItem, which reaches every mounted row (never the unmounted ones).
  const cases: { name: string; changeOneBound: number }[] = [
    { name: "combobox", changeOneBound: MOUNTED_BOUND },
    { name: "combobox-pinned", changeOneBound: MOUNTED_BOUND },
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
          const resize = await open.measure("resize");
          expect(resize.rowRendersMax).toBeLessThanOrEqual(rows);
          report.push(`resize ${resize.rowRendersMax} rows ${resize.taskMsP95} ms`);
          await open.close();
          if (has.changeOne) {
            // A fresh page, so the changed item (the third) is mounted: its row re-renders on every
            // step, and nothing past the bound does.
            const changing = await server.open(name, n);
            const change = await changing.measure("changeOne");
            expect(change.rowRendersMean).toBeGreaterThanOrEqual(1);
            expect(change.rowRendersMax).toBeLessThanOrEqual(changeOneBound);
            report.push(`change ${change.rowRendersMax} rows ${change.taskMsP95} ms`);
            await changing.close();
          }
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

  // A list opened long windows from its first commit: it never mounts every row for one render
  // before the window takes over (the mount bound above reads the DOM after that commit is gone).
  for (const name of ["combobox", "combobox-pinned"]) {
    test(`${name}: the first render of a long list mounts only the window`, async () => {
      for (const n of [1000, 10000]) {
        const open = await server.open(name, n);
        const { peakMounts, peakRenders } = open.mountCounts;
        console.log(`${name} at ${n}: mount peak ${peakMounts} rows mounted, ${peakRenders} rendered in one commit`);
        expect(peakMounts).toBeGreaterThan(0);
        expect(peakMounts).toBeLessThanOrEqual(MOUNTED_BOUND);
        expect(peakRenders).toBeLessThanOrEqual(MOUNTED_BOUND);
        await open.close();
      }
    });
    test(`${name}: a list that opens short and grows past the bound windows as it grows`, async () => {
      const open = await server.open(`${name}&start=10`, 10000);
      const { page } = open;
      expect((await open.counts()).rows).toBe(name === "combobox" ? 10 : 11);
      const peak = await page.evaluate(async () => {
        const w = window as unknown as {
          __grow(): void;
          __visibleList: {
            renderCounts: { start(): void; stop(): void; read(names: readonly string[]): { peakMounts: number } };
          };
        };
        w.__visibleList.renderCounts.start();
        w.__grow();
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
        w.__visibleList.renderCounts.stop();
        return w.__visibleList.renderCounts.read(["ComboboxOption", "ComboboxCaseRow"]).peakMounts;
      });
      const { rows } = await open.counts();
      console.log(`${name} grown 10 to 10000: mount peak ${peak}, mounted ${rows}`);
      expect(peak).toBeLessThanOrEqual(MOUNTED_BOUND);
      expect(rows).toBeLessThanOrEqual(MOUNTED_BOUND);
      expect(await page.locator('[role="option"][aria-setsize="10000"]').count()).toBeGreaterThan(0);
      await open.close();
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

  for (const name of ["combobox", "combobox-pinned"]) {
    test(`${name}: the arrows and Return reach rows that were not mounted, and a typed query picks its match`, async () => {
      const open = await server.open(name, 10000);
      const { page } = open;
      await page.evaluate(() =>
        (window as unknown as { __visibleListControls: { filter(): HTMLElement } }).__visibleListControls
          .filter()
          .focus(),
      );
      for (let index = 0; index < 40; index++) await page.keyboard.press("ArrowDown");
      expect(await activeRow(page)).toMatchObject({ mounted: true, inView: true, posinset: "40", setsize: "10000" });
      await page.keyboard.press("Enter");
      expect(await submitted(page)).toBe("id-39");
      await page.keyboard.type("item 09999");
      await page.keyboard.press("ArrowDown");
      expect((await activeRow(page)).text).toContain("item 09999");
      await page.keyboard.press("Enter");
      expect(await submitted(page)).toBe("id-9999");
      await open.close();
    });
  }
  test("rows of different heights: one leaving from above the view leaves no row over another and no gap", async () => {
    const open = await server.open("combobox&vary=1", 1000);
    const { page } = open;
    const rowsOverlapping = () =>
      page.evaluate(() => {
        const rows = [...document.querySelectorAll<HTMLElement>("[role='option']")]
          .map((row) => ({ text: row.textContent ?? "", rect: row.getBoundingClientRect() }))
          .sort((a, b) => a.rect.top - b.rect.top);
        const wrong: string[] = [];
        for (let index = 1; index < rows.length; index++) {
          const gap = rows[index]!.rect.top - rows[index - 1]!.rect.bottom;
          if (Math.abs(gap) > 0.75) wrong.push(`${rows[index - 1]!.text} | ${rows[index]!.text}: ${gap.toFixed(1)} px`);
        }
        return { mounted: rows.length, wrong };
      });
    await page.evaluate(() => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      scroller.scrollTop = 400;
    });
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    expect((await rowsOverlapping()).wrong).toEqual([]);
    // Rows of both heights move up by one place: each must keep its own size, not the one before it.
    for (const id of ["id-1", "id-5", "id-7"])
      await page.evaluate((id) => (window as unknown as { __removeItem(id: string): void }).__removeItem(id), id);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    const after = await rowsOverlapping();
    expect(after.mounted).toBeGreaterThan(0);
    expect(after.wrong).toEqual([]);
    await open.close();
  });

  // The pinned path the folder popover takes (pinned actions over a ScrollArea viewport that the
  // rows window in), with the action above the list and under it.
  type Page = Awaited<ReturnType<VisibleListsServer["open"]>>["page"];
  const frame = (page: Page) => page.evaluate(() => new Promise((done) => requestAnimationFrame(done)));
  /** The active row as `activeRow` reads it, and the pinned action: an option outside the scroller,
   * on the page, and on its side of the scroller's view. */
  async function pinnedState(page: Page, placement: "top" | "bottom") {
    const active = await activeRow(page);
    const pinned = await page.evaluate((placement) => {
      const scroller = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller();
      const row = document.querySelector<HTMLElement>(".ui-combobox-pinned [role='option']");
      if (!row) return { mounted: false, placed: false, active: false };
      const view = scroller.getBoundingClientRect();
      const box = row.getBoundingClientRect();
      const onPage = box.height > 0 && box.top >= 0 && box.bottom <= window.innerHeight;
      const side = placement === "top" ? box.bottom <= view.top + 0.5 : box.top >= view.bottom - 0.5;
      const owner = document.activeElement?.closest("[aria-activedescendant]") ?? document.activeElement;
      return {
        mounted: true,
        placed: onPage && side && !scroller.contains(row),
        active: owner?.getAttribute("aria-activedescendant") === row.id,
      };
    }, placement);
    return { active, pinned };
  }

  for (const placement of ["top", "bottom"] as const) {
    for (const n of [1000, 10000]) {
      const name = `combobox-pinned&placement=${placement}`;
      test(`combobox-pinned (${placement}) at ${n}: End, Home, the arrows and Return reach rows that were not mounted`, async () => {
        const open = await server.open(name, n);
        const { page } = open;
        await page.evaluate(() =>
          (window as unknown as { __visibleListControls: { filter(): HTMLElement } }).__visibleListControls
            .filter()
            .focus(),
        );
        const press = async (key: string) => {
          await page.keyboard.press(key);
          await frame(page);
          return pinnedState(page, placement);
        };
        const onRow = (position: number) => ({
          active: { mounted: true, inView: true, posinset: String(position), setsize: String(n) },
          pinned: { mounted: true, placed: true, active: false },
        });
        const onPinned = { pinned: { mounted: true, placed: true, active: true } };
        // End reaches the last of the collection, the pinned action; the row above it is the
        // list's last, off-screen until then.
        expect(await press("End")).toMatchObject(onPinned);
        expect(await press("ArrowUp")).toMatchObject(onRow(n));
        await page.keyboard.press("Enter");
        expect(await submitted(page)).toBe(`id-${n - 1}`);
        expect(await press("Home")).toMatchObject(onRow(1));
        for (let step = 1; step <= 40; step++) expect(await press("ArrowDown")).toMatchObject(onRow(1 + step));
        await page.keyboard.press("Enter");
        expect(await submitted(page)).toBe("id-40");
        // Up from the top leaves the list for the field, then wraps to the pinned action and on to
        // the last row.
        expect(await press("Home")).toMatchObject(onRow(1));
        expect(await press("ArrowUp")).toMatchObject({
          active: { mounted: false },
          pinned: { mounted: true, placed: true, active: false },
        });
        expect(await press("ArrowUp")).toMatchObject(onPinned);
        expect(await press("ArrowUp")).toMatchObject(onRow(n));
        expect((await open.counts()).rows).toBeLessThanOrEqual(MOUNTED_BOUND);
        await open.close();
      });

      test(`combobox-pinned (${placement}) at ${n}: scrolled anywhere, the view has no blank and no overlap`, async () => {
        const open = await server.open(name, n);
        const { page } = open;
        const found: string[] = [];
        for (const fraction of [0, 0.1, 0.37, 0.5, 0.83, 1]) {
          await page.evaluate((fraction) => {
            const scroller = (
              window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
            ).__visibleListControls.scroller();
            scroller.scrollTop = Math.round(fraction * (scroller.scrollHeight - scroller.clientHeight));
          }, fraction);
          await frame(page);
          found.push(
            ...(await page.evaluate((fraction) => {
              const scroller = (
                window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
              ).__visibleListControls.scroller();
              const view = scroller.getBoundingClientRect();
              const options = [...scroller.querySelectorAll<HTMLElement>("[role='option']")];
              const rows = options.map((row) => row.getBoundingClientRect()).sort((a, b) => a.top - b.top);
              const at = `${Math.round(fraction * 100)}%`;
              if (!rows.length) return [`${at}: no rows`];
              // The rows' spacer spans exactly the rows: outside it is the list's own padding.
              const spacer = options[0]!.parentElement!.getBoundingClientRect();
              const wrong: string[] = [];
              for (let y = Math.max(view.top, spacer.top); y < Math.min(view.bottom, spacer.bottom); y += 4)
                if (!rows.some((row) => row.top <= y && y < row.bottom))
                  wrong.push(`${at}: blank at ${(y - view.top).toFixed(0)} px`);
              for (let index = 1; index < rows.length; index++) {
                const overlap = rows[index - 1]!.bottom - rows[index]!.top;
                if (overlap > 0.75) wrong.push(`${at}: rows overlap by ${overlap.toFixed(1)} px`);
              }
              return wrong;
            }, fraction)),
          );
        }
        expect(found).toEqual([]);
        expect((await open.counts()).rows).toBeLessThanOrEqual(MOUNTED_BOUND);
        await open.close();
      });
    }
  }
});
