// The visible-only list numbers for a PR body: each case (test/browser/visible-lists/*.case.tsx)
// at each N, from one production build of the harness in headless Chromium
// (test/support/visibleLists.ts says what each column measures).
//   bun bench/visible-lists.bench.ts listbox,combobox [counts=1000,10000]
/// <reference types="bun" />
import { startVisibleLists, type VisibleStep } from "../test/support/visibleLists";

const CASES = (process.argv[2] ?? "listbox").split(",");
const COUNTS = (process.argv[3] ?? "1000,10000").split(",").map(Number);
const STEPS: VisibleStep[] = ["type", "scroll", "hover", "changeOne", "resize"];

const server = await startVisibleLists();
try {
  console.log("| case | N | rows | DOM nodes | step | row renders (max/mean) | main ms p95 (p50) |");
  console.log("|---|---|---|---|---|---|---|");
  for (const name of CASES) {
    for (const n of COUNTS) {
      for (const step of STEPS) {
        // A fresh page per step, so one step's state (a typed query) is not the next one's.
        const open = await server.open(name, n);
        const has = await open.page.evaluate((step) => {
          const controls = (window as unknown as { __visibleListControls: Record<string, unknown> })
            .__visibleListControls;
          return step === "type" ? !!controls.filter : step === "changeOne" ? !!controls.changeOne : true;
        }, step);
        if (has) {
          const { rows, domNodes } = await open.counts();
          const numbers = await open.measure(step);
          console.log(
            `| ${name} | ${n} | ${rows} | ${domNodes} | ${step} | ${numbers.rowRendersMax} / ${numbers.rowRendersMean.toFixed(1)} | ${numbers.taskMsP95} (${numbers.taskMsP50}) |`,
          );
        }
        await open.close();
      }
    }
  }
} finally {
  await server.stop();
}
