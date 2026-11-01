// What a glass floating over the chat covers, for its in-place blur (ui/glass/seeThroughBlur.ts):
// the chat stage's own blocks (its header, the transcript, a strip or a panel in it), never a whole
// column. The Summary popover sits in the stage and Session Info beside the chat's column
// (.acpmux-main), so a column-wide filter would also take the composer and make the column one
// stacking context; the stage's blocks are only what is under the glass. The surfaces themselves are
// skipped by seeThroughBlur.
import type { CoveredCandidates } from "../../ui/glass/seeThroughBlur";

export const chatUnderGlass: CoveredCandidates = (surface) =>
  surface.closest(".acpmux-shell")?.querySelectorAll(".acpmux-stage > *") ?? [];
