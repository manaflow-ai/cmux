// Opening or closing anything in the transcript never moves the reader's view: the line they
// clicked (a tool group, a tool, command or MCP call, a folded thought, a settled run, "Worked for",
// a subagent group, a failure's Details) stays where it was on screen while what it opens or closes
// lays out and its fold plays (fold.ts). VirtualTranscript holds it (App.tsx): each placement pass
// during the hold moves the offset by however far the line moved, and none of them follows the
// latest row meanwhile.
//
// Followed to the latest row, the opened body grows down from the clicked line, so the view no
// longer shows the latest row and stops following it (Jump to latest shows); a body that still
// leaves the latest row in view keeps following. Closing at the transcript's end is the one place the
// line can move: with nothing below to fill the view, the browser clamps the offset and the rows
// above come down by what closed, as they do in every scroller.
import { foldMs } from "./fold";

/// The disclosures a click holds in place.
export const FOLD_TOGGLE = "button.is-toggle[aria-expanded], button.cv-subagents[aria-expanded], summary";
/// What a collapsible's header sends up (bubbling, cancelable) to be held where it is drawn while its
/// body opens or closes (useAnchoredCollapse.ts); the transcript that holds it cancels it.
export const ANCHORED_COLLAPSE_EVENT = "cmux:anchored-collapse";
/// How long a hold outlasts its fold: the last frame's measure, and rows a "Worked for" inserts.
export const FOLD_SETTLE_MS = 150; // motion-allow: a hold timer after the fold, not an animation

export type FoldAnchor = {
  toggle: HTMLElement;
  /// Where the line was drawn when clicked (its viewport top).
  top: number;
  /// When the hold ends (performance.now()).
  until: number;
};

/// The disclosure line `target` is on, inside one of `scroller`'s rows; undefined for anything else.
export function foldToggleAt(target: EventTarget | null, scroller: HTMLElement): HTMLElement | undefined {
  const element = target && typeof (target as Element).closest === "function" ? (target as Element) : null;
  const toggle = element?.closest<HTMLElement>(FOLD_TOGGLE);
  return toggle && scroller.contains(toggle) && toggle.closest(".acpmux-row") ? toggle : undefined;
}

/// Holds `toggle` where it is drawn now, for its fold and a little after.
export function holdFold(toggle: HTMLElement, now = performance.now()): FoldAnchor {
  return { toggle, top: toggle.getBoundingClientRect().top, until: now + foldMs(toggle) + FOLD_SETTLE_MS };
}

/// Puts the held line back where it was clicked by moving `scroller`'s offset. False once the hold
/// is over (its time is up, or the line left the transcript), and the view is the reader's again.
export function keepFold(anchor: FoldAnchor, scroller: HTMLElement, now = performance.now()): boolean {
  if (now > anchor.until || !anchor.toggle.isConnected) return false;
  const moved = anchor.toggle.getBoundingClientRect().top - anchor.top;
  if (Math.abs(moved) >= 0.5) scroller.scrollTop += moved;
  return true;
}
