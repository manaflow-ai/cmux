// Opening or closing anything in the transcript never moves the reader's view: the line they
// clicked (a tool group, a tool, command or MCP call, a folded thought, a settled run, "Worked for",
// a subagent group, a failure's Details) stays where it was on screen while what it opens or closes
// lays out and its fold plays (fold.ts). VirtualTranscript holds it (App.tsx): each placement pass
// during the hold moves the offset by however far the line moved, and none of them follows the
// latest row meanwhile.
//
// Followed to the latest row, the opened body grows down from the clicked line, so the view no
// longer shows the latest row and stops following it (Jump to latest shows); a body that still
// leaves the latest row in view keeps following. Closing at the transcript's end holds the line too
// (Leo, ask-a736047107: "WHEN I EXPAND THEM IT JUMPS ME DOWN AND WHEN I COLLAPSE IT JUMPS ME UP"):
// the click keeps the content at least as tall as the view's end (`foldRoomFor`), so what closed
// leaves room under the rows instead of the browser clamping the offset and bringing every row down
// by it. That room follows the view's end as the reader scrolls up and goes once the rows grow back
// into it (`trimmedFoldRoom`); a send and Jump to latest drop it (App.tsx).
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

/// The content end a click on a disclosure keeps: the view's end now (offset plus height), whole
/// pixels up, or the end already kept when that is further down.
export function foldRoomFor(scrollTop: number, clientHeight: number, kept = 0): number {
  return Math.max(kept, Math.ceil(scrollTop + clientHeight));
}

/// The kept end after a scroll or a placement pass: as it is while a fold holds its line; else no
/// further down than the view's end (`viewEnd`, the reader scrolled up), and 0 once the rows' own end
/// (`rowsEnd`) reaches it, when nothing of it is room any more.
export function trimmedFoldRoom(kept: number, viewEnd: number, rowsEnd: number, holding: boolean): number {
  if (kept <= 0) return 0;
  if (holding) return kept;
  const next = Math.min(kept, Math.ceil(viewEnd));
  return next <= rowsEnd + 0.5 ? 0 : next;
}
