// What Settings > Agents reads from the harnesses' health (cx-ny85): shared by the Harnesses card
// and the section list's badge, so the list does not load the card.
import type { HarnessRow, HarnessesState } from "./ops";

/** Rows the page can update with one click (outdated, and no sudo needed). */
export function updatable(state: HarnessesState | null | undefined): HarnessRow[] {
  return (state?.harnesses ?? []).filter(
    (row) => row.outdated && row.update && !row.update.elevated && !updateUnsettled(state, row.id),
  );
}

/** Creation and unknown outcomes cannot authorize a second update. */
export function updateUnsettled(state: HarnessesState | null | undefined, id: string): boolean {
  return (state?.jobs ?? []).some((job) => job.profiles.includes(id) && job.state !== "exited");
}

/** Whether Settings > Agents wants a look: a harness is outdated or signed out. */
export function harnessesNeedAttention(state: HarnessesState | null | undefined): boolean {
  return (state?.harnesses ?? []).some((row) => row.outdated || row.auth === "signedOut");
}
