// The transcript's layout watch from a gallery or a browser harness (src/agent-session/acpmux/conversation/
// layoutWatch.ts): what moved in view with no input, append or declared move, by the motion model's
// invariant (I1..I10). Threshold 1 px, the watch's own. WARN-ONLY for now: `warnUnexplained` logs and
// returns the events, it fails nothing; the next change makes it fail.
import type { Page } from "playwright";
import type { LayoutEvent } from "../../src/agent-session/acpmux/conversation/layoutWatch";

export type { LayoutEvent };

/// Asks the page to watch from its first script on (before `goto`): a page that is not a dev or nightly
/// build starts its watch too.
export async function watchLayoutFromLoad(page: Page): Promise<void> {
  await page.addInitScript(() => {
    (window as { __cmuxLayoutWatch?: boolean }).__cmuxLayoutWatch = true;
  });
}

/// Starts the page's watch now, when the page has one, and clears what it held; false when it has none.
export async function startLayoutWatch(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const handle = window.cmuxLayoutWatch;
    if (!handle) return false;
    handle.start();
    handle.clear();
    return true;
  });
}

/// The page's unexplained events so far (none when the page has no watch).
export async function unexplainedLayout(page: Page): Promise<LayoutEvent[]> {
  return page.evaluate(() => window.cmuxLayoutWatch?.unexplained() ?? []);
}

/// Logs each unexplained event under `label` and returns them. Warn-only: it never throws.
export async function warnUnexplained(page: Page, label: string): Promise<LayoutEvent[]> {
  const events = await unexplainedLayout(page);
  for (const event of events)
    console.warn(
      `[layoutWatch] ${label}: ${event.invariant} ${event.cause} ${event.rowId ?? event.selector ?? ""} ${event.deltaPx}px (frame ${event.frame}${event.expect ? `, expect ${event.expect}` : ""})`,
    );
  return events;
}
