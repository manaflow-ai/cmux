// Exit before move: when a fold takes text away, the text is gone before anything travels.
//
// Leo, 2026-11-21: "i rather dislike the folding right now bc the text is still visible as it gets
// folded/"collapsed" ... that text hiding as it travels so it doesnt show weird overlays is the big one.
// we prev dealt with this when collapsing groups. we must hide text faster and sooner".
//
// Every fold that hides text (a body closing, fold.ts; a "Worked for" closing, turnFold.ts; a turn's
// end, turnEndFold.ts; the read "New since you looked" line, unread.css) plays two clocks:
// - the exit: the leaving text fades from its ink to 0 over `exitLeadMs` (half the quick step, 40 ms),
//   on the house ease-out, which drops it fastest at the start;
// - the move: heights and translates on the fold's own clock, starting when the exit ends, so no text
//   that leaves is drawn while anything travels (design/chat-fold-motion.md).
// Opening plays no lead: nothing leaves, and Leo's "No fade in. Just boom" (2026-10-24) still holds.
import { MOTION_EASE_OUT, MOTION_MS } from "../../../motion/scale.generated";

/// The exit's length (ms): half the quick step, the step for "anything leaving" (motion-scale).
/// The CSS twin is `--cv-exit-lead` (conversation.css).
export const EXIT_LEAD_MS = MOTION_MS.quick / 2;

/// The exit's curve: the house ease-out, so the text is fainter sooner than on a straight line.
export const EXIT_EASING = MOTION_EASE_OUT;

/// The gallery's arms (`data-exit-lead` on an ancestor, gallery `agent-pane.turn-end-fold`): `lead`,
/// shipped, the 40 ms lead; `none`, before, the text fading on the move's own clock; `quick`, a whole
/// quick step (80 ms) of lead.
export type ExitLeadLook = "lead" | "none" | "quick";
export const EXIT_LEAD_LOOKS: readonly ExitLeadLook[] = ["lead", "none", "quick"];
export const EXIT_LEAD_ATTR = "data-exit-lead";

/// The lead the look over `node` asks for (ms), before the fold's own bounds.
function lookLeadMs(node: Element | null | undefined): number {
  const look = node?.closest?.(`[${EXIT_LEAD_ATTR}]`)?.getAttribute(EXIT_LEAD_ATTR);
  return look === "none" ? 0 : look === "quick" ? MOTION_MS.quick : EXIT_LEAD_MS;
}

/// The exit lead for a fold of `foldMs` whose leaving text is drawn at `ink` (0 to 1): none for a fold
/// that plays nothing, a share of it for text already faint (a close that turns back an open), and never
/// more than a third of the fold (half for the `quick` arm), so a short fold stays mostly move. `node`:
/// where the fold plays, for the gallery's arm.
export function exitLeadMs(foldMs: number, ink = 1, node?: Element | null): number {
  if (!(foldMs > 0) || !(ink > 0)) return 0;
  const lead = lookLeadMs(node);
  return Math.min(lead, foldMs / (lead > EXIT_LEAD_MS ? 2 : 3)) * Math.min(1, ink);
}

/// The keyframes of a body that closes on one animation of `lead + move` ms: its ink goes to 0 over
/// the lead while its height holds, then its height goes on `easing`. Each segment carries its own
/// curve, so the animation itself runs linear.
export function exitThenClose(
  from: { height: number; opacity: number },
  to: { height: number },
  lead: number,
  move: number,
  easing: string,
): Keyframe[] {
  if (lead <= 0)
    return [
      { height: `${from.height}px`, opacity: from.opacity, easing },
      { height: `${to.height}px`, opacity: 0 },
    ];
  return [
    { height: `${from.height}px`, opacity: from.opacity, easing: EXIT_EASING },
    { offset: lead / (lead + move), height: `${from.height}px`, opacity: 0, easing },
    { height: `${to.height}px`, opacity: 0 },
  ];
}
