// l10n-allow-file: test names and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The cloud Add repository picker draws only the repositories in view (visible-only list rule):
// the same mounted rows at 1,000 and 10,000 repositories, bounded by the list's viewport, and a
// hover, a scroll step or a typed key re-renders only the rows it touches. The case is
// test/browser/visible-lists/cloud-repository-picker.case.tsx (the real picker, a stubbed host);
// the measure is test/support/visibleLists.ts. Times are printed, not asserted.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("visible-lists-cloud-repository-picker.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { startVisibleLists } = await import("./support/visibleLists");
  type Server = Awaited<ReturnType<typeof startVisibleLists>>;
  const CASE = "cloud-repository-picker";
  // The list is at most 260 px tall (sessionInfo.css) and a row is 32 px (28 px button, 4 px gap):
  // 9 rows in view. Allowed: the viewport and one viewport of overscan on each side.
  const VIEWPORT_ROWS = Math.ceil(260 / 32);
  const MAX_ROWS = VIEWPORT_ROWS * 3;
  let server: Server;

  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  test("mounted rows do not grow with the repositories and stay within the viewport's bound", async () => {
    const rows: number[] = [];
    for (const n of [1000, 10000]) {
      const open = await server.open(CASE, n);
      const counts = await open.counts();
      console.log(`${CASE} N=${n}: ${counts.rows} rows, ${counts.domNodes} DOM nodes (bound ${MAX_ROWS} rows)`);
      rows.push(counts.rows);
      expect(counts.rows).toBeLessThanOrEqual(MAX_ROWS);
      await open.close();
    }
    expect(Math.abs(rows[0]! - rows[1]!) / Math.max(rows[0]!, rows[1]!)).toBeLessThanOrEqual(0.1);
  });

  for (const n of [1000, 10000]) {
    test(`N=${n}: a hover, a scroll step and a typed key re-render only the rows they touch`, async () => {
      const limits = { hover: 2, scroll: 3 } as const;
      for (const step of ["hover", "scroll"] as const) {
        const open = await server.open(CASE, n);
        const numbers = await open.measure(step);
        console.log(
          `${CASE} N=${n} ${step}: renders max ${numbers.rowRendersMax}, p95 ${numbers.taskMsP95} ms (p50 ${numbers.taskMsP50})`,
        );
        expect(numbers.rowRendersMax).toBeLessThanOrEqual(limits[step]);
        await open.close();
      }
      const open = await server.open(CASE, n);
      const { rows } = await open.counts();
      const typed = await open.measure("type");
      console.log(
        `${CASE} N=${n} type: renders max ${typed.rowRendersMax} (mounted ${rows}), p95 ${typed.taskMsP95} ms (p50 ${typed.taskMsP50})`,
      );
      expect(typed.rowRendersMax).toBeLessThanOrEqual(rows);
      await open.close();
    });
  }
});
