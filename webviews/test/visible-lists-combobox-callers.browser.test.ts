// cmux-web-test-timeout: 300
// The real pickers over ui/Combobox draw the visible area, whatever their list's length (Leo
// 2026-11-18: "we draw the visible area, right? ... there are so many places where I'm pretty sure
// we're just drawing the whole list. And we need to be able to guard against that"). Each caller
// case (test/browser/visible-lists/*.case.tsx: ProjectChooser, AddProjectPanel's directory listing,
// EnvironmentPicker's machines and its machine card, ThemePicker, FontPicker, FolderPopover with and
// without pinned actions) is opened on a production build in Chromium (test/support/visibleLists.ts)
// at 1,000 and 10,000 items:
// - mounted rows are the same at both lengths (within 10%), at most the rows in the scroller's view,
//   the window's overscan each side, the keyboard's row and the pinned actions;
// - a hover re-renders at most the two rows it moved between, one scroll step at most three rows.
// And the windowed rows keep their places when the data moves them while the list is open: a
// machine that leaves the environment list (rowPresence.ts) and themes starred and unstarred leave
// no row over another and no stale gap. The main-thread times per step are printed, not asserted.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-combobox-callers.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  /** Combobox's VirtualRows overscan: rows mounted past each edge of the view. */
  const OVERSCAN = 8;
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  /** The most rows a windowed list of this scroller may mount: those that fit in its view (at its
   * shortest row), the overscan each side, the keyboard's row and the pinned actions. */
  const mountedBound = (page: Page) =>
    page.evaluate((overscan) => {
      const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
        .__visibleListControls;
      const scroller = controls.scroller();
      const heights = [...scroller.querySelectorAll<HTMLElement>('[role="option"]')]
        .map((row) => row.getBoundingClientRect().height)
        .filter((height) => height > 0);
      const inView = Math.ceil(scroller.clientHeight / Math.min(...heights)) + 1;
      const pinned = document.querySelectorAll('.ui-combobox-pinned [role="option"]').length;
      return inView + overscan * 2 + 1 + pinned;
    }, OVERSCAN);

  const cases = [
    "project-chooser",
    "add-project",
    "environment-picker",
    "environment-picker-card",
    "theme-picker",
    "font-picker",
    "folder-popover",
    "folder-popover-pinned",
  ];

  for (const name of cases) {
    describe(name, () => {
      test("mounts the same rows at 1,000 and 10,000 items; a hover or scroll re-renders only the rows it touches", async () => {
        const mounted: number[] = [];
        for (const n of [1000, 10000]) {
          const open = await server.open(name, n);
          const { rows, domNodes } = await open.counts();
          mounted.push(rows);
          expect(rows).toBeLessThanOrEqual(await mountedBound(open.page));
          const scroll = await open.measure("scroll");
          expect(scroll.rowRendersMax).toBeLessThanOrEqual(3);
          const hover = await open.measure("hover");
          expect(hover.rowRendersMax).toBeLessThanOrEqual(2);
          await open.close();
          const typing = await server.open(name, n);
          const type = await typing.measure("type");
          await typing.close();
          console.log(
            `${name} at ${n}: rows ${rows}, nodes ${domNodes}, scroll ${scroll.rowRendersMax} rows ${scroll.taskMsP95} ms, ` +
              `hover ${hover.rowRendersMax} rows ${hover.taskMsP95} ms, key ${type.rowRendersMax} rows ${type.taskMsP95} ms p95`,
          );
        }
        expect(Math.abs(mounted[1]! - mounted[0]!)).toBeLessThanOrEqual(Math.ceil(mounted[0]! * 0.1));
      });
    });
  }

  /** Each mounted row against the one above it: the gap beyond their margins (a heading drawn in a
   * margin is part of it). Negative is a row over another, positive a stale gap. */
  const misplaced = (page: Page) =>
    page.evaluate(() => {
      const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
        .__visibleListControls;
      const rows = [...controls.scroller().querySelectorAll<HTMLElement>('[role="option"]')]
        .map((row) => {
          const box = row.getBoundingClientRect();
          const style = getComputedStyle(row);
          return {
            text: (row.textContent ?? "").slice(0, 20),
            top: box.top,
            bottom: box.bottom,
            above: Number.parseFloat(style.marginTop) || 0,
            below: Number.parseFloat(style.marginBottom) || 0,
          };
        })
        .sort((a, b) => a.top - b.top);
      const wrong: string[] = [];
      for (let index = 1; index < rows.length; index++) {
        const [a, b] = [rows[index - 1]!, rows[index]!];
        const gap = b.top - a.bottom - a.below - b.above;
        if (Math.abs(gap) > 0.75) wrong.push(`${a.text} | ${b.text}: ${gap.toFixed(1)} px`);
      }
      return wrong;
    });

  test("environment picker: a machine that leaves the open list leaves no row over another", async () => {
    const open = await server.open("environment-picker", 60);
    const { page } = open;
    await page.evaluate(() =>
      (window as unknown as { __environmentCase: { remove(id: string): void } }).__environmentCase.remove("id-2"),
    );
    // The row shrinks out (--agent-motion-move), then goes.
    await page.waitForTimeout(600);
    expect(await misplaced(page)).toEqual([]);
    await open.close();
  });

  test("theme picker: starring and unstarring themes in the open list leaves every heading in its place", async () => {
    const open = await server.open("theme-picker", 60);
    const { page } = open;
    await page.evaluate(() => {
      (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
      ).__visibleListControls.scroller().scrollTop = 0;
    });
    const star = async (name: string) => {
      await page.evaluate((name) => document.querySelector<HTMLElement>(`[data-theme-star="${name}"]`)!.click(), name);
      await page.waitForTimeout(120);
    };
    // The case stars 10, 20 and 45: unstar them all (the headings go, every row moves up), then star one.
    for (const name of ["item 00045 foxtrot", "item 00020 echo", "item 00010 charlie"]) await star(name);
    expect(await misplaced(page)).toEqual([]);
    await star("item 00002 charlie");
    expect(await misplaced(page)).toEqual([]);
    await open.close();
  });
});
