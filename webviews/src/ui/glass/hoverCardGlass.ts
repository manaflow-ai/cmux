// The one hover card material over a chat (glass.css "A HOVER CARD BLURS WHAT IT COVERS"): a card
// floating over the chat makes the stage's blocks under it blur themselves in its rounded rect
// (seeThroughBlur.ts), so it needs no underlay and the art shows through its tint, as a link's card
// does. Every hover card takes it: AnchoredCard's callers pass it, and ui/Tooltip.tsx gives it to
// every card (`ui-card`) it draws, so a card made with Tooltip (a "Received N messages" row's
// preview, a subagent's card, a goal's or a pull request's checks) is never the near-opaque page
// glass (Leo, 2026-11-14, on that preview: "this has no transparency at all + is not scrollable").
// A page with no chat stage has nothing here to blur, and its cards keep the page's glass.
import type { CoveredCandidates, SeeThroughOptions } from "./seeThroughBlur";

/** The chat's dock (the composer): it never takes a filter (it would re-anchor the composer's fixed
 * menus), so a glass over it keeps its underlay there. The dock has a box only while it floats over
 * the transcript (bottomStack.css); elsewhere it is `display: contents`, so its parts are matched. */
export const CHAT_DOCK = ".acpmux-dock, .acpmux-dock > *";

/** What a hover card covers: it is portaled out of the shell, so the page's chat stage blocks and
 * Session Info (a menu over Session Info's card blurs its rows too). */
export const hoverCardUnder: CoveredCandidates = (surface) =>
  surface.ownerDocument.querySelectorAll(".acpmux-stage > *, .acpmux-session-info");

/** A hover card's in-place blur: its blocks carry data-glass-under="hover-card" (glass.css). */
export const hoverCardGlass: SeeThroughOptions = {
  owner: "hover-card",
  keepUnderlayOver: (surface) => surface.ownerDocument.querySelectorAll(CHAT_DOCK),
};
