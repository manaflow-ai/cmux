import type { CustomizeBarOutcome } from "./CustomizeBar";
import type { CustomizeBarState } from "./customizeBarModel";

/** Whether the bar draws anything: a preview, or the outcome of the person's last click. */
export function customizeBarShows(state: CustomizeBarState, outcome: CustomizeBarOutcome): boolean {
  return (
    state.kind === "preview" || outcome.kind === "applied" || outcome.kind === "saved" || outcome.kind === "failed"
  );
}
