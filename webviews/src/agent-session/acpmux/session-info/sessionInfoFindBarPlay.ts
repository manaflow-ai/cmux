// l10n-allow-file: gallery fixture helpers, not shipped UI.
// Find in Chat's bar with Session Info open, in each of its places (SessionInfo.tsx sessionInfoStage):
// the bar belongs to the chat's column and sits left of the panel, never under it (Leo, 2026-11-03: "oh
// no the command f overlaps with the session info.."). Wide panes: in the gutter at 1600px, pushing at
// 1100px, over the chat at 1200px. Narrow panes: over the chat at 740px with the bar narrowed beside it;
// at 528px the chat has no room for the bar beside the panel, so the panel steps aside when Find opens
// (findBarCramped).
import type { Play } from "../../../gallery/play";
import { setHeaderState } from "../header/headerState";
import { setSessionInfoOpen } from "./sessionInfoState";
import { GalleryPane } from "./SessionInfoSurfaces.gallery";

export type FindBarProps = { surface: "transcript"; find: true };
type Box = { left: number; right: number; top: number; bottom: number };

const intersects = (a: Box, b: Box) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

/// Opens Session Info (the toggle, where a saved state waits for it), then Find (Cmd-F), and asserts the
/// bar lies inside the chat's column and clear of the panel.
export const findBesidePanel: Play = async (ctx) => {
  const closed = 'button.acpmux-session-info-toggle[aria-pressed="false"]';
  await ctx.waitFor(() => ctx.document.querySelector("button.acpmux-session-info-toggle"));
  if (ctx.document.querySelector(closed)) await ctx.click({ selector: closed });
  await ctx.waitFor(
    () => ctx.document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
  );
  await ctx.press("Meta+f");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-find__bar .find-pill"));
  // The panel may still be leaving when it stepped aside for a cramped chat.
  await ctx.waitFor(() => {
    const panel = ctx.document.querySelector("aside.acpmux-session-info");
    return !panel || panel.getAttribute("data-presence") === "shown";
  });
  const bar = ctx.find({ selector: ".acpmux-find__bar .find-pill" }).getBoundingClientRect();
  const column = ctx.find({ selector: ".acpmux-main .acpmux-scroll" }).getBoundingClientRect();
  if (bar.left < column.left - 0.5 || bar.right > column.right + 0.5)
    throw new Error(`Find bar ${bar.left}-${bar.right} is outside the chat's column ${column.left}-${column.right}`);
  const panel = ctx.document.querySelector("aside.acpmux-session-info")?.getBoundingClientRect();
  if (panel && intersects(bar, panel))
    throw new Error(`Find bar ${bar.left}-${bar.right} overlaps Session Info ${panel.left}-${panel.right}`);
};

export const findBarCovers = ["agent-session/acpmux/conversation/ChatFindBar.tsx#ChatFindBar"];
export const findBarLoad = async () => {
  setHeaderState({ inspector: true });
  setSessionInfoOpen(true);
  return GalleryPane;
};
export const findBarStyles = () => Promise.all([import("../styles.css"), import("../conversation/conversation.css")]);
