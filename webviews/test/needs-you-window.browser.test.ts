// cmux-web-test-timeout: 300
// The header's Needs you list draws the visible area at any length, measured on a production build
// in Chromium (test/support/visibleLists.ts, case visible-lists/needs-you.case.tsx) at 1,000 and
// 10,000 asks: mounted rows the same within 10% and at most the rows of the 520 px list plus the
// overscan on each side; one scroll step draws at most the rows it brings in, one changed ask only its
// row. Main-thread times per step are printed, not asserted.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { startVisibleLists, type VisibleListsServer } from "./support/visibleLists";

await requireBrowserLane("needs-you-window.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  // NeedsYou.tsx draws NEEDS_YOU_OVERSCAN (6) rows past each edge; a row is at least ~40 px.
  const MOUNTED_BOUND = Math.ceil(520 / 40) + 2 * 6 + 1;
  let server: VisibleListsServer;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  test("Needs you mounts the same rows at 1,000 and 10,000 asks; steps draw only the rows they touch", async () => {
    const mounted: number[] = [];
    const nodes: number[] = [];
    for (const n of [1000, 10000]) {
      const open = await server.open("needs-you", n);
      const { rows, domNodes } = await open.counts();
      mounted.push(rows);
      nodes.push(domNodes);
      // The changed ask (the third) is in view before the scroll steps move past it.
      const change = await open.measure("changeOne");
      const scroll = await open.measure("scroll");
      console.log(
        `needs-you at ${n}: rows ${rows}, nodes ${domNodes}, scroll ${scroll.rowRendersMax} rows (mean ${scroll.rowRendersMean}) p95 ${scroll.taskMsP95} ms p50 ${scroll.taskMsP50} ms, change ${change.rowRendersMax} rows p95 ${change.taskMsP95} ms p50 ${change.taskMsP50} ms`,
      );
      expect(rows).toBeLessThanOrEqual(MOUNTED_BOUND);
      expect(scroll.rowRendersMax).toBeLessThanOrEqual(3);
      expect(change.rowRendersMax).toBeLessThanOrEqual(1);
      await open.close();
    }
    expect(Math.abs(mounted[1]! - mounted[0]!)).toBeLessThanOrEqual(Math.ceil(mounted[0]! * 0.1));
    expect(Math.abs(nodes[1]! - nodes[0]!)).toBeLessThanOrEqual(Math.ceil(nodes[0]! * 0.1));
  });
});
