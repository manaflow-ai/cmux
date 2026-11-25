// The gallery stage's box tracker (src/gallery/shift.ts `startBoxTracker`, judged by followJudge.ts),
// for a page that is not a gallery frame: the pane's dev entry a papercut test opens. Bundled once to
// a script and added to the page, so the test reads the same per-frame samples and the same stray
// moves the gallery's shift check reads.
import path from "node:path";
import type { Page } from "playwright";
import type { BoxShift } from "../../src/gallery/shift";

declare global {
  interface Window {
    cmuxBoxTracker?: {
      start(): void;
      stop(): BoxShift;
    };
  }
}

let bundled: Promise<string> | undefined;

/** The tracker's script: an IIFE that sets `window.cmuxBoxTracker`. */
function trackerScript(): Promise<string> {
  bundled ??= (async () => {
    const result = await Bun.build({
      entrypoints: [path.join(import.meta.dir, "boxTrackerEntry.ts")],
      target: "browser",
      format: "iife",
      minify: false,
    });
    if (!result.success) throw new Error(`box tracker bundle: ${result.logs.map(String).join("\n")}`);
    return await result.outputs[0]!.text();
  })();
  return bundled;
}

/** Adds the tracker to `page` (after it loaded; again after a reload). */
export async function installBoxTracker(page: Page): Promise<void> {
  await page.addScriptTag({ content: await trackerScript() });
}

/**
 * Adds the tracker to every later document of `page` and starts it as each one's DOM is parsed, so a
 * reload is tracked from its first painted frame (a box that arrives is not judged; one that then moves is).
 */
export async function installBoxTrackerOnLoad(page: Page): Promise<void> {
  const start = `document.addEventListener("DOMContentLoaded", () => window.cmuxBoxTracker.start(), { once: true });`;
  await page.addInitScript({ content: `${await trackerScript()}\n${start}` });
}
