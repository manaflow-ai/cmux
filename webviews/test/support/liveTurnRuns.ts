// The `runs` arm of live-turn-work, for a browser test whose subject is a finished run in a running turn.
//
// A test that clicks, measures or waits for a finished run while its turn runs pins this arm.
// `line` keeps finished runs hidden until the turn ends. `runs` is the default again and draws
// finished runs as closed lines; tests must open a run before inspecting the calls inside it.
//
// The arm goes in the debug key that `experimentArm` reads after the host's override
// (experiments/experiment.ts), so it also reaches a page whose harness or gallery frame installs its own
// `globalThis.cmuxExperiments` for another experiment. Other arms already in the key are kept. Call it
// after any init script of the test that clears localStorage, and before `page.goto`.
import type { Page } from "playwright";

/// The same arm for send-stream-motion's page (test/browser/send-stream-motion.harness.tsx), which
/// open120Hz loads at its creation, before an init script can run: a part of the page's query.
export const LIVE_TURN_RUNS_QUERY = "&liveTurnWork=runs";

export async function pinLiveTurnRuns(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const key = "cmux.experiments";
    try {
      const text = localStorage.getItem(key);
      const kept: unknown = text ? JSON.parse(text) : undefined;
      const arms = kept && typeof kept === "object" && !Array.isArray(kept) ? kept : {};
      localStorage.setItem(key, JSON.stringify({ ...arms, "live-turn-work": "runs" }));
    } catch {
      // A document with no storage (about:blank before the navigation): the page under test has it.
    }
  });
}
