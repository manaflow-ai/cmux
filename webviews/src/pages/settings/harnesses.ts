// What Settings > Agents reads from the harnesses' health (cx-ny85): shared by the Harnesses card
// and the section list's badge, so the list does not load the card.
import type { HarnessRow, HarnessesState } from "./ops";

/** Rows the page can update with one click (outdated, no sudo needed, a channel the owner runs). */
export function updatable(state: HarnessesState | null | undefined): HarnessRow[] {
  return (state?.harnesses ?? []).filter((row) => offersUpdate(row) && !updateUnsettled(state, row.id));
}

/** Whether a row shows Update: the owner refuses elevated plans and channels it cannot run. */
export function offersUpdate(row: HarnessRow): boolean {
  return !!row.outdated && !!row.update && !row.update.elevated && row.ownerUpdate === true;
}

/** A job still being created, running, or whose creation reply was lost blocks a second update;
 * any end observation (`exited`, even with an unknown outcome) settles it. */
export function updateUnsettled(state: HarnessesState | null | undefined, id: string): boolean {
  return (state?.jobs ?? []).some((job) => job.profiles.includes(id) && job.state !== "exited");
}

/** Whether Settings > Agents wants a look: a harness is outdated, signed out or its sign-in expired. */
export function harnessesNeedAttention(state: HarnessesState | null | undefined): boolean {
  return (state?.harnesses ?? []).some((row) => row.outdated || row.auth === "signedOut" || row.auth === "expired");
}
