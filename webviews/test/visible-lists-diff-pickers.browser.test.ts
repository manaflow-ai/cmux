// cmux-web-test-timeout: 300
// The diff viewer's two pickers draw only the visible area (Leo, 2026-11-18: "we draw the visible
// area, right?"): the Base picker (BranchBasePicker.tsx) and the jump-to-file palette
// (DiffToolbar.tsx), each open over N items (test/browser/visible-lists/*.case.tsx).
// - Mounted rows are the same at 1,000 and 10,000 items (within 10%), and at most three viewports
//   of rows (the viewport and one viewport of overscan each side) plus the highlighted row.
// - A hover renders at most the two rows whose highlight changes, one changed file renders one row,
//   one scroll step renders at most the rows that enter, and a typed key at most the mounted rows.
// Main-thread milliseconds are printed, not asserted.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import type { VisibleListOpen, VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("visible-lists-diff-pickers.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { startVisibleLists } = await import("./support/visibleLists");
  let server: VisibleListsServer;

  beforeAll(async () => {
    server = await startVisibleLists();
  }, 240_000);
  afterAll(async () => {
    await server?.stop();
  });

  /** Rows the list's viewport holds: its height over one option's height. */
  const viewportRows = (open: VisibleListOpen) =>
    open.page.evaluate(() => {
      const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
        .__visibleListControls;
      const scroller = controls.scroller();
      const row = scroller.querySelector<HTMLElement>('[role="option"]')!;
      return Math.ceil(scroller.clientHeight / row.getBoundingClientRect().height);
    });

  const cases = [
    { name: "branch-base-picker", changeOne: false },
    { name: "jump-to-file", changeOne: true },
  ];

  /** Each mounted option's aria-posinset and aria-setsize, and the item number in its text. */
  const optionSets = (open: VisibleListOpen) =>
    open.page.evaluate(() => {
      const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
        .__visibleListControls;
      return [...controls.scroller().querySelectorAll<HTMLElement>('[role="option"]')].map((option) => ({
        item: Number(/item 0123 (\d{5})/.exec(option.textContent ?? "")?.[1]),
        posinset: Number(option.getAttribute("aria-posinset")),
        setsize: Number(option.getAttribute("aria-setsize")),
      }));
    });
  const twoFrames = (open: VisibleListOpen) =>
    open.page.evaluate(
      () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))),
    );

  // Both pickers draw only a capped number of matches (BranchBasePicker's EMPTY_FILTER_GROUP_CAP
  // and FILTERED_TOTAL_CAP, the palette's JUMP_ROW_CAP), with a "N more" note for the rest. A
  // screen reader hears the size of the whole set of matches, not of the capped rows, and each
  // option's place in it.
  const sets = [
    // Five groups of N/5 refs, ref k in group k % 5 at place k / 5; every ref matches the query.
    { name: "branch-base-picker", place: (item: number, n: number) => (item % 5) * (n / 5) + Math.floor(item / 5) + 1 },
    // Files sort by name, which is the item number.
    { name: "jump-to-file", place: (item: number) => item + 1 },
  ];
  for (const { name, place } of sets) {
    test(`${name}: aria-setsize is every match, past the cap, and aria-posinset each option's place`, async () => {
      const n = 1000;
      const open = await server.open(name, n);
      try {
        const check = async (when: string) => {
          const options = await optionSets(open);
          const sizes = [...new Set(options.map((option) => option.setsize))].join(",");
          console.log(`${name} N=${n} ${when}: ${options.length} options, aria-setsize ${sizes}`);
          expect(options.length).toBeGreaterThan(0);
          for (const option of options) {
            expect(option.setsize).toBe(n);
            expect(option.posinset).toBe(place(option.item, n));
          }
        };
        await check("empty filter");
        await open.page.evaluate(() => {
          const scroller = (
            window as unknown as { __visibleListControls: { scroller(): HTMLElement } }
          ).__visibleListControls.scroller();
          scroller.scrollTop = scroller.scrollHeight;
        });
        await twoFrames(open);
        await check("empty filter, scrolled to the end");
        await open.page.locator('[role="dialog"] input').fill("item 0123");
        await twoFrames(open);
        await check('filter "item 0123"');
      } finally {
        await open.close();
      }
    });
  }

  for (const { name, changeOne } of cases) {
    test(`${name}: mounted rows hold at 1,000 and 10,000 items and stay within the viewport and overscan`, async () => {
      const rows: number[] = [];
      for (const n of [1000, 10_000]) {
        const open = await server.open(name, n);
        try {
          const counts = await open.counts();
          const view = await viewportRows(open);
          const bound = view * 3 + 1;
          console.log(
            `${name} N=${n}: ${counts.rows} rows, ${counts.domNodes} DOM nodes, viewport ${view} rows, bound ${bound}`,
          );
          expect(counts.rows).toBeLessThanOrEqual(bound);
          rows.push(counts.rows);
        } finally {
          await open.close();
        }
      }
      expect(Math.abs(rows[0]! - rows[1]!)).toBeLessThanOrEqual(Math.ceil(Math.max(...rows) * 0.1));
    });

    for (const n of [1000, 10_000]) {
      test(`${name} at ${n}: hover, scroll${changeOne ? ", one changed file" : ""} and typing render only the rows they touch`, async () => {
        const steps: { step: "hover" | "scroll" | "changeOne" | "type"; max: (mounted: number) => number }[] = [
          { step: "hover", max: () => 2 },
          { step: "scroll", max: () => 3 },
          ...(changeOne ? [{ step: "changeOne" as const, max: () => 1 }] : []),
          { step: "type", max: (mounted) => mounted },
        ];
        for (const { step, max } of steps) {
          // A fresh page per step, as the bench does: a typed query is not the next step's state.
          const open = await server.open(name, n);
          try {
            const { rows } = await open.counts();
            const numbers = await open.measure(step, 10);
            console.log(
              `${name} N=${n} ${step}: row renders max ${numbers.rowRendersMax} (mean ${numbers.rowRendersMean.toFixed(1)}), main ms p95 ${numbers.taskMsP95} (p50 ${numbers.taskMsP50})`,
            );
            expect(numbers.rowRendersMax).toBeLessThanOrEqual(max(rows));
          } finally {
            await open.close();
          }
        }
      });
    }
  }
});
