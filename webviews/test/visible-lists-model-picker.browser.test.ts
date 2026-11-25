// cmux-web-test-timeout: 300
// The composer's model picker draws the rows in view, not its whole catalog (Leo 2026-11-18: "we
// draw the visible area, right? ... we need to be able to guard against that"). The real picker
// (test/browser/visible-lists/model-picker.case.tsx) with 1,000 and 10,000 models, in a production
// build in headless Chromium: the same rows mount at both, at most one viewport more on each side
// and the active row; a hover re-renders the two rows whose highlight moves, one model's change its
// own row, a scroll step the rows it brings in, a typed key no more rows than are mounted. The
// main-thread times are printed, not asserted (CI noise).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { requireBrowserLane } from "./support/requireBrowserLane";
import type { VisibleListsServer, VisibleStep } from "./support/visibleLists";

await requireBrowserLane("visible-lists-model-picker.browser.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { startVisibleLists } = await import("./support/visibleLists");
  let server: VisibleListsServer | undefined;
  beforeAll(async () => {
    server = await startVisibleLists();
  });
  afterAll(async () => {
    await server?.stop();
  });

  async function step(n: number, name: VisibleStep) {
    // A fresh page per step, so one step's state (a typed query, the pointer) is not the next one's.
    const open = await server!.open("model-picker", n);
    try {
      const counts = await open.counts();
      // The rows one viewport of the list holds.
      const viewRows = await open.page.evaluate(() => {
        const controls = (window as unknown as { __visibleListControls: { scroller(): HTMLElement } })
          .__visibleListControls;
        const scroller = controls.scroller();
        const row = scroller.querySelector<HTMLElement>('[data-key^="model:"]')!.getBoundingClientRect().height;
        return Math.ceil(scroller.clientHeight / row);
      });
      const numbers = await open.measure(name);
      console.log(
        `model-picker N=${n} ${name}: rows ${counts.rows}, DOM nodes ${counts.domNodes}, view rows ${viewRows}, ` +
          `row renders max ${numbers.rowRendersMax} mean ${numbers.rowRendersMean.toFixed(1)}, ` +
          `main ms p95 ${numbers.taskMsP95} p50 ${numbers.taskMsP50}`,
      );
      return { ...counts, viewRows, numbers };
    } finally {
      await open.close();
    }
  }

  test("the model picker mounts the rows in view and re-renders only the rows a step changes", async () => {
    for (const name of ["hover", "changeOne", "scroll", "type"] as const) {
      const small = await step(1_000, name);
      const large = await step(10_000, name);
      // Mounted rows do not grow with N.
      expect(Math.abs(large.rows - small.rows), `${name}: mounted rows at 1,000 and 10,000`).toBeLessThanOrEqual(
        Math.ceil(small.rows * 0.1),
      );
      expect(Math.abs(large.domNodes - small.domNodes), `${name}: DOM nodes at 1,000 and 10,000`).toBeLessThanOrEqual(
        Math.ceil(small.domNodes * 0.1),
      );
      for (const at of [small, large]) {
        // The viewport's rows (a partial one at each edge), one viewport each side, and the active row.
        expect(at.rows, `${name}: mounted rows against ${at.viewRows} in view`).toBeLessThanOrEqual(
          3 * at.viewRows + 3,
        );
        const renders = at.numbers.rowRendersMax;
        if (name === "hover") expect(renders, "hover: row renders").toBeLessThanOrEqual(2);
        if (name === "changeOne") expect(renders, "one model changed: row renders").toBeLessThanOrEqual(1);
        // One scroll step of one row brings in at most a row at each edge and the one it uncovers.
        if (name === "scroll") expect(renders, "scroll step: row renders").toBeLessThanOrEqual(3);
        if (name === "type") expect(renders, "typed key: row renders").toBeLessThanOrEqual(at.rows);
      }
    }
  });
});
