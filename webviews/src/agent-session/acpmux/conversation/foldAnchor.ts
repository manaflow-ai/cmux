// Away from the bottom, opening or closing a disclosure keeps the reader's view: the line they
// clicked (a tool group, a tool, command or MCP call, a folded thought, a settled run, "Worked for",
// a subagent group, a failure's Details) stays where it was on screen while what it opens or closes
// lays out and its fold plays (fold.ts). VirtualTranscript holds it (App.tsx): each placement pass
// during the hold moves the offset by however far the line moved, and none of them follows the
// latest row meanwhile.
//
// Tool/work disclosures clicked at or near the end instead pin the bottom and move the thread
// as one stack (App.tsx, Leo 2026-10-31). Other disclosures keep the clicked line even when closing
// near the end: foldRoomFor prevents a browser clamp, and trimmedFoldRoom releases that room as the
// reader scrolls up, the rows fill it, or a send/Jump to latest returns to following.
import { foldMs } from "./fold";

/// The disclosures a click holds in place: every control that opens or closes something in its row
/// (a button or a `role="button"` line with `aria-expanded`: a tool or sent message's line, Show
/// more, Show all lines, Raw, a file list's "+N more"), a `<summary>`, and a header that is its
/// toggle edge to edge (`data-header-toggle`, headerToggle.ts: an agent message's line, the edits
/// card's header, a disclosure row's line). A menu's trigger
/// (`aria-haspopup`) opens no body in the row and is left out. An `aria-pressed` button is held only
/// when it says it changes its block's height (`data-fold-toggle`: Wrap lines, a tool output's Raw):
/// a reply's Pin and Read aloud are `aria-pressed` too, and holding them would stop following a
/// reply that streams on.
export const FOLD_TOGGLE = [
  "button[aria-expanded]:not([aria-haspopup])",
  '[role="button"][aria-expanded]:not([aria-haspopup])',
  "summary",
  "[data-header-toggle]",
  // Toggles that change their block's height in place: Wrap lines, Raw, a diagram's chart or code.
  "button[aria-pressed][data-fold-toggle]",
  "button.cv-diagram__toggle",
].join(", ");
/// The controls a click lands on: one inside a toggle is its own, not the toggle's.
const NESTED_CONTROL =
  'button, a[href], [role="button"], [role="link"], summary, input, textarea, select, [role="menuitem"]';
/// What a collapsible's header sends up (bubbling, cancelable) to be held where it is drawn while its
/// body opens or closes (useAnchoredCollapse.ts); the transcript that holds it cancels it.
export const ANCHORED_COLLAPSE_EVENT = "cmux:anchored-collapse";
/// How long a hold outlasts its fold: the last frame's measure, and rows a "Worked for" inserts.
export const FOLD_SETTLE_MS = 150; // motion-allow: a hold timer after the fold, not an animation
/// The shortest hold, so a toggle with no fold (Reduce Motion, a body that lays out late) is still
/// held while what it opened is measured and placed. A hold that kept extending while its line moved
/// re-placed a tall prompt under the pointer and its Show less missed the click. The reader's own
/// scroll lets go of it sooner.
export const FOLD_HOLD_MIN_MS = 400; // motion-allow: a hold timer, not an animation

/// Whether the physical scroller is at (or within the normal follow deadband of) its end.
export function atFoldBottom(scrollTop: number, clientHeight: number, scrollHeight: number, deadband: number): boolean {
  return scrollHeight > clientHeight + 0.5 && scrollHeight - clientHeight - scrollTop <= deadband;
}

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
  if (!toggle || !scroller.contains(toggle) || !toggle.closest(".acpmux-row")) return undefined;
  // A control of its own inside the toggle (a sent line's recipient, its Copy) opens nothing there.
  const control = element?.closest<HTMLElement>(NESTED_CONTROL);
  return control && control !== toggle && toggle.contains(control) ? undefined : toggle;
}

/// The lines that open a body under themselves: a click holds the line itself.
const HEADER_TOGGLE =
  'button.is-toggle[aria-expanded], button.cv-subagents[aria-expanded], [role="button"][aria-expanded], summary, [data-header-toggle]';

/// What a click on `toggle` holds in place. A line that opens a body under itself holds itself. Any
/// other control (Show more, Show all lines, "+N more", Raw) may sit under or beside the body it
/// opens or closes, so its row holds by its top: the body grows and shrinks downward and nothing
/// above it moves, the control with it. A row whose top is above `scroller`'s view (Show less under
/// a long output, scrolled down to) holds the control instead: held by its top, the row would close
/// up above the view and leave it blank, so the body shrinks up into the control, which stays where
/// it was clicked.
export function foldHoldTarget(toggle: HTMLElement, scroller?: HTMLElement): HTMLElement {
  if (toggle.matches(HEADER_TOGGLE)) return toggle;
  const row = toggle.closest<HTMLElement>(".acpmux-row");
  if (!row) return toggle;
  if (scroller && row.getBoundingClientRect().top < scroller.getBoundingClientRect().top - 0.5) return toggle;
  return row;
}

/// Holds `toggle` where it is drawn now, for its fold and a little after.
export function holdFold(toggle: HTMLElement, now = performance.now()): FoldAnchor {
  const until = now + Math.max(foldMs(toggle) + FOLD_SETTLE_MS, FOLD_HOLD_MIN_MS);
  return { toggle, top: toggle.getBoundingClientRect().top, until };
}

/// The hold for a click on `toggle`: the one its press started (`pressed`, same line, still on), kept
/// at the place the line was pressed at and timed from the click, so a line that streaming moved
/// between press and release goes back to where the reader pressed it; else a new one.
export function clickFold(toggle: HTMLElement, pressed: FoldAnchor | undefined, now = performance.now()): FoldAnchor {
  const fresh = holdFold(toggle, now);
  return pressed && pressed.toggle === toggle && foldHolding(pressed, now) ? { ...fresh, top: pressed.top } : fresh;
}

/// Whether a wheel event is the reader scrolling the transcript: up or down, not sideways (a code
/// block's horizontal scroll keeps the hold).
export function verticalWheel(event: { deltaX: number; deltaY: number }): boolean {
  return Math.abs(event.deltaY) > Math.abs(event.deltaX);
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
/// further down than the view's end (`viewEnd`, the reader scrolled up), and 0 once the content
/// would be that tall anyway: the rows' own end (`rowsEnd`) or the view's height (`viewHeight`, a
/// scroller is never shorter than its view) reaches it, when nothing of it is room any more. Nor
/// once the rows end above the view's top: the room would be all the reader sees, so it goes and
/// the view comes back to the rows' end.
export function trimmedFoldRoom(
  kept: number,
  viewEnd: number,
  rowsEnd: number,
  holding: boolean,
  viewHeight = 0,
): number {
  if (kept <= 0) return 0;
  if (holding) return kept;
  if (viewHeight > 0 && rowsEnd <= viewEnd - viewHeight + 0.5) return 0;
  const next = Math.min(kept, Math.ceil(viewEnd));
  return next <= Math.max(rowsEnd, viewHeight) + 0.5 ? 0 : next;
}

/// Whether `anchor` still holds its line (its time is not up and the line is still drawn).
export function foldHolding(anchor: FoldAnchor | undefined, now = performance.now()): boolean {
  return anchor !== undefined && now <= anchor.until && anchor.toggle.isConnected;
}
