// Experiment arms a browser test pins before its page loads (experiments/experiment.ts reads
// `globalThis.cmuxExperiments`; the gallery's stage frame keeps what is there and adds its own).
// A suite pins the earlier arm of a look it does not test, so it keeps checking what it is about.
import type { Page } from "playwright";

/// The clock on the running turn's live line, as before liveTurnClock.experiment.ts `top` moved it
/// over the work ("Working for 32s"); transcript-live-turn-clock.test.ts covers `top`.
export const CLOCK_ON_LINE = { "live-turn-clock": "line" } as const;

/// Installs `arms` on every document `page` loads from now on.
export async function pinArms(page: Page, arms: Readonly<Record<string, string>>): Promise<void> {
  await page.addInitScript((pinned) => {
    const host = globalThis as { cmuxExperiments?: Record<string, string> };
    host.cmuxExperiments = { ...host.cmuxExperiments, ...pinned };
  }, arms);
}
