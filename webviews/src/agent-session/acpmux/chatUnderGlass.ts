// What a glass floating over the chat covers, for its in-place blur (ui/glass/seeThroughBlur.ts):
// the chat stage's own blocks (its header, the transcript, a strip or a panel in it), never a whole
// column. The Summary popover sits in the stage and Session Info beside the chat's column
// (.acpmux-main), so a column-wide filter would also take the composer and make the column one
// stacking context; the stage's blocks are only what is under the glass. The surfaces themselves are
// skipped by seeThroughBlur.
import type { CoveredCandidates, SeeThroughOptions } from "../../ui/glass/seeThroughBlur";

export const chatUnderGlass: CoveredCandidates = (surface) =>
  surface.closest(".acpmux-shell")?.querySelectorAll(".acpmux-stage > *") ?? [];

// The composer never takes a filter (it would re-anchor the composer's fixed menus), so a glass over
// it keeps its underlay there: a short pane's Session Info reaches down over the composer.
const composer: CoveredCandidates = (surface) =>
  surface.closest(".acpmux-shell")?.querySelectorAll(".acpmux-dock") ?? [];

/** Session Info's overlay. */
export const chatGlass: SeeThroughOptions = { keepUnderlayOver: composer };

/** The Summary popover: its blocks carry data-glass-under="summary", which summary.css switches off
 * while it hides the card (Find, review, inspect), with no observer to see that happen. */
export const summaryGlass: SeeThroughOptions = { owner: "summary", keepUnderlayOver: composer };

// A hover card (a link's, a pull request's) is portaled out of the shell: it covers the stage of the
// page's chat, and keeps its underlay over the composer. Leo, 2026-11-05: "this awkward wannabe glass
// but kind of just opaque thing": Chromium's backdrop left the transcript's text reading through the
// card's tint, so the card blurs what it covers in place, as the Summary popover does.
export const chatUnderHoverCard: CoveredCandidates = (surface) =>
  surface.ownerDocument.querySelectorAll(".acpmux-stage > *");

/** A hover card's in-place blur: its blocks carry data-glass-under="hover-card" (glass.css). */
export const hoverCardGlass: SeeThroughOptions = {
  owner: "hover-card",
  keepUnderlayOver: (surface) => surface.ownerDocument.querySelectorAll(".acpmux-dock"),
};
