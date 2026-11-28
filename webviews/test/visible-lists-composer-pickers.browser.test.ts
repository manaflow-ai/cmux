// cmux-web-test-timeout: 300
// The composer's menus draw the rows near their view, not their whole list (Leo, 2026-11-18: "we draw
// the visible area, right? ... we need to be able to guard against that"): the + menu (Picker, with
// the host's catalog rows) and the mode menu (AccessMenu, with the agent's modes), the real
// components in a production build (test/browser/visible-lists/composer-*.case.tsx), at 1,000 and
// 10,000 rows. Mounted rows stay the same at both counts and within the menu's viewport and one
// viewport each side; a hover, a changed row and a scroll step draw only the rows they touch. Main
// thread milliseconds are printed, never asserted. Neither menu has a filter field, so there is no
// typing step.
//
// A changed row is also counted by support/commitRenders.ts, rows by their selector: every component
// that did work, and every host element given new props, is charged to the row its DOM sits in, so a
// row redrawn by ui/Menu's MenuItem or Base UI's item, not only by its named row component, counts.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { installRowRenderCounter, type RowRenderCount, type RowRenderCounter } from "./support/commitRenders";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("visible-lists-composer-pickers.browser.test.ts", async () => {
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  }, 240_000);
  afterAll(async () => {
    await server?.stop();
  });

  /** Rows the menu's viewport holds at its shortest mounted row. */
  async function viewportRows(page: import("playwright").Page): Promise<number> {
    return page.evaluate(() => {
      const controls = (
        window as unknown as { __visibleListControls: { scroller(): HTMLElement; rowSelector: string } }
      ).__visibleListControls;
      const scroller = controls.scroller();
      const heights = [...scroller.querySelectorAll<HTMLElement>(controls.rowSelector)]
        .map((row) => row.getBoundingClientRect().height)
        .filter((height) => height > 0);
      return Math.ceil(scroller.clientHeight / Math.min(...heights));
    });
  }

  /** Each case's rows (composer-*.case.tsx). */
  const rowSelectors: Record<string, string> = {
    "composer-plus": '[role="menuitem"]',
    "composer-mode": '[role="menuitemradio"]',
  };

  for (const name of ["composer-plus", "composer-mode"]) {
    test(`${name}: one changed row draws that row and no other (rows by selector)`, async () => {
      for (const n of [1000, 10000]) {
        const open = await server.open(name, n);
        // react-dom keeps the commit hook object it found and calls its onCommitFiberRoot on each
        // commit, so the counter wraps it in place once the case is open.
        await open.page.evaluate(installRowRenderCounter);
        for (let step = 0; step < 4; step++) {
          const count = await open.page.evaluate(async (rows): Promise<RowRenderCount> => {
            const scope = window as unknown as {
              __cmuxRowRenders: RowRenderCounter;
              __visibleListControls: { list(): HTMLElement; changeOne(): void };
            };
            scope.__cmuxRowRenders.begin(scope.__visibleListControls.list(), rows);
            scope.__visibleListControls.changeOne();
            await new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done())));
            return scope.__cmuxRowRenders.end();
          }, rowSelectors[name]!);
          console.log(
            `${name} N=${n} changeOne by selector: ${count.rerendered} rows rendered (${count.wasted} for nothing), ${count.added} added`,
          );
          // The changed row, and only it.
          expect(count.rerendered).toBe(1);
          expect(count.wasted).toBe(0);
        }
        await open.close();
      }
    }, 120_000);

    test(`${name}: mounted rows do not grow with N, and a step draws only its rows`, async () => {
      const mounted: Record<number, number> = {};
      for (const n of [1000, 10000]) {
        const open = await server.open(name, n);
        const { rows, domNodes } = await open.counts();
        const inView = await viewportRows(open.page);
        // The viewport's rows, one viewport each side, and the focused row.
        const bound = 3 * inView + 1;
        console.log(`${name} N=${n}: ${rows} rows mounted, ${domNodes} DOM nodes, bound ${bound} (${inView} in view)`);
        expect(rows).toBeLessThanOrEqual(bound);
        mounted[n] = rows;
        await open.close();
        for (const [step, most] of [
          ["hover", 2],
          ["changeOne", 1],
          ["scroll", 3],
        ] as const) {
          const page = await server.open(name, n);
          const numbers = await page.measure(step, 8);
          console.log(
            `${name} N=${n} ${step}: row renders max ${numbers.rowRendersMax}, main ms p95 ${numbers.taskMsP95} (p50 ${numbers.taskMsP50})`,
          );
          expect(numbers.rowRendersMax).toBeLessThanOrEqual(most);
          await page.close();
        }
      }
      expect(Math.abs(mounted[10000]! - mounted[1000]!)).toBeLessThanOrEqual(Math.ceil(0.1 * mounted[1000]!));
    }, 280_000);
  }
});
