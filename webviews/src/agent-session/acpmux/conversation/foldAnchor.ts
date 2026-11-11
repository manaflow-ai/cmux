// Away from the bottom, opening or closing a disclosure keeps the reader's view: the line they
// clicked (a tool group, a tool, command or MCP call, a folded thought, a settled run, "Worked for",
// a subagent group, a failure's Details) stays where it was on screen while what it opens or closes
// lays out and its fold plays (fold.ts). VirtualTranscript holds it (App.tsx): each placement pass
// during the hold moves the offset by however far the line moved, and none of them follows the
// latest row meanwhile.
//
// A disclosure closed with the view at its very end instead pins the bottom and moves the thread
// as one stack: what closes pulls it down, leaving no blank room under the rows (App.tsx `beginBottomStackFold`, Leo 2026-11-03: "it's
// weird to collapse and get all that empty space at the bottom"). Away from the end a close keeps
// the clicked line: foldRoomFor prevents a browser clamp, and trimmedFoldRoom releases that room as
// the reader scrolls up, the rows fill it, or a send/Jump to latest returns to following.
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

/// How far up the view a disclosure line sat, as a share of the view's height from its foot, when
/// opening it at the latest row pinned the bottom. Opening no longer pins it (VirtualTranscript.tsx
/// `beginBottomStackFold`); only transcript-details-toggle-steady-browser.test.ts still reads it.
export const BOTTOM_PIN_SHARE = 0.6;
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

/// Whether a click on `toggle` opens what it holds: a closed disclosure (`aria-expanded="false"`, on
/// itself or on its header's button) or the `<summary>` of a closed `<details>`.
export function opensBody(toggle: HTMLElement): boolean {
  if (toggle.tagName === "SUMMARY") return !(toggle.parentElement as HTMLDetailsElement | null)?.open;
  const expanded = toggle.hasAttribute("aria-expanded")
    ? toggle
    : toggle.querySelector("[aria-expanded]:not([aria-haspopup])");
  return expanded?.getAttribute("aria-expanded") === "false";
}

/// The cut that keeps a row moving up with the bottom stack from drawing past the line the rows
/// under it hold (App.tsx): `over` is how far the row's foot lands below that line once it settles
/// (0 for the opened row, less for one above it), `from` how far the stack starts below where it
/// settles. Keyframes on the stack's own eased progress, so the cut row's foot reaches the line as
/// the stack carries it there and nothing of it ever covers the held rows; none when it never does.
export function pushUpCut(over: number, from: number): Keyframe[] {
  const start = over + from;
  if (from <= 0.5 || start <= 0.5) return [];
  const until = Math.min(1, start / from);
  return [
    { offset: 0, clipPath: `inset(0 0 ${start}px 0)` },
    { offset: until, clipPath: "inset(0 0 0px 0)" },
    { offset: 1, clipPath: "inset(0 0 0px 0)" },
  ];
}

export type FoldAnchor = {
  toggle: HTMLElement;
  /// Where the line was drawn when clicked (its viewport top).
  top: number;
  /// When the hold ends (performance.now()), once its change is placed (`pending`).
  until: number;
  /// How long the hold lasts after its change is placed: the fold, the settle, at least FOLD_HOLD_MIN_MS.
  span?: number;
  /// The latest the hold waits for its change to be placed (`FOLD_DRAW_WAIT_MS` after the click).
  latest?: number;
  /// The hold waits for the click's change to be drawn and its row placed (`notePlacement`), and only
  /// then runs `span`. A hold built by hand (no `latest`) is timed from `until` alone.
  pending?: boolean;
  /// The control the reader clicked and the state it said then (`toggleState`): the change is drawn
  /// once it says another. A control that says nothing counts as drawn.
  control?: HTMLElement;
  from?: string;
  /// Finds the held line and the control again when an update draws them anew (`lineSelector`), in `root`.
  find?: string;
  controlFind?: string;
  root?: ParentNode;
};

/// The longest a hold waits for the click's change to be drawn and placed (Leo, 2026-11-10, on a
/// recording at load ~260: "when things get slow this tool call expansion situatoin gets insanely
/// f***ed"). The hold was timed from the click alone (about 400 ms). Under load the page laid out what
/// opened, and the transcript measured the row's new height, later than that: no placement pass ran in
/// between, and the first one after found the hold over. It neither put the line back nor stopped
/// following the latest row, and the view jumped to the bottom with the clicked line gone from it. The
/// hold now starts its span on the first pass that has the change placed; this only bounds a change
/// that never comes. The reader's own scroll lets go sooner.
export const FOLD_DRAW_WAIT_MS = 5_000; // motion-allow: a hold's upper bound, not an animation

/// What a disclosure control says of its state: a `<summary>`'s details open or not, its own
/// `aria-expanded` or `aria-pressed`, or its header button's `aria-expanded` (a `data-header-toggle`
/// line). Undefined for a control that says nothing (a diagram's chart or code switch).
export function toggleState(control: HTMLElement): string | undefined {
  if (control.tagName === "SUMMARY") {
    const details = control.parentElement;
    return details?.tagName === "DETAILS" ? String((details as HTMLDetailsElement).open) : undefined;
  }
  if (typeof control.getAttribute !== "function") return undefined;
  const own = control.getAttribute("aria-expanded") ?? control.getAttribute("aria-pressed");
  if (own !== null) return own;
  return control.querySelector?.("[aria-expanded]:not([aria-haspopup])")?.getAttribute("aria-expanded") ?? undefined;
}

/// The id-keyed lines a streamed update can draw anew (a call's, a group's, a run's: the ids outlast
/// a regroup, keepOpenedLineModel.ts) and a transcript row; anything else is not found again.
const LINE_IDS = ["data-tool-id", "data-tool-group", "data-tool-run"] as const;

/// A selector that finds `node` again once React draws it anew, or undefined. The id is looked for
/// under each of the three names: a group that grows into a run draws its key as `data-tool-run`.
export function lineSelector(node: HTMLElement): string | undefined {
  if (typeof node.getAttribute !== "function") return undefined;
  const escape = (value: string) => value.replace(/["\\]/g, "\\$&");
  for (const name of LINE_IDS) {
    const value = node.getAttribute(name);
    if (!value) continue;
    const tag = node.tagName.toLowerCase();
    return LINE_IDS.map((any) => `${tag}[${any}="${escape(value)}"]`).join(", ");
  }
  const row = node.getAttribute("data-row-id");
  return row && node.classList?.contains("acpmux-row") ? `.acpmux-row[data-row-id="${escape(row)}"]` : undefined;
}

/// When `anchor` lets go: `latest` while it waits for its change to be placed, else `until`.
function deadline(anchor: FoldAnchor): number {
  return anchor.pending && anchor.latest !== undefined ? anchor.latest : anchor.until;
}

/// `node` if it is still drawn, else what `find` finds in the hold's transcript now.
function drawnAgain(
  node: HTMLElement,
  find: string | undefined,
  root: ParentNode | undefined,
): HTMLElement | undefined {
  if (node.isConnected) return node;
  return (find && root?.querySelector<HTMLElement>(find)) || undefined;
}

/// The held line as drawn now: the same node, or the one an update drew in its place (found by its
/// id); undefined once it is gone.
function heldLine(anchor: FoldAnchor): HTMLElement | undefined {
  const line = drawnAgain(anchor.toggle, anchor.find, anchor.root);
  if (line) anchor.toggle = line;
  return line;
}

/// Tells a pending hold, on each placement pass before `keepFold`, whether the click's change is in:
/// the control says another state than when clicked (or says none), and the row is not `unplaced`
/// (drawn at a height the transcript has not measured yet). The first pass that has it starts the
/// hold's span, so the line stays put however long the render took. Under load no pass may run
/// between the click and that one: the hold waits through the gap, up to `latest`.
export function notePlacement(anchor: FoldAnchor, unplaced: boolean, now = performance.now()): void {
  if (!anchor.pending) return;
  const control = anchor.control ? drawnAgain(anchor.control, anchor.controlFind, anchor.root) : undefined;
  if (control) anchor.control = control;
  const drawn = anchor.from === undefined || !control || toggleState(control) !== anchor.from;
  if (!drawn || unplaced) return;
  anchor.pending = false;
  anchor.until = Math.max(anchor.until, Math.min(anchor.latest ?? anchor.until, now + (anchor.span ?? 0)));
}

/// A message row's first line, on its own line under the row (messageLineLook.ts, stacked: a sent
/// message, an agent message, a received line, a folded group's head). It toggles its row, so a click
/// on it holds the row's line, as a click on the line does; the first line itself goes as the row opens.
const FIRST_LINE = ".cv-msgline__preview";

/// The disclosure line `target` is on, inside one of `scroller`'s rows; undefined for anything else.
export function foldToggleAt(target: EventTarget | null, scroller: HTMLElement): HTMLElement | undefined {
  const element = target && typeof (target as Element).closest === "function" ? (target as Element) : null;
  const line = element?.closest(FIRST_LINE)?.previousElementSibling;
  const toggle = line?.matches(FOLD_TOGGLE) ? (line as HTMLElement) : element?.closest<HTMLElement>(FOLD_TOGGLE);
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

/// Holds `toggle` where it is drawn now, for its fold and a little after, counted from the first
/// placement pass that has the click's change placed (`notePlacement`): `control` is what the reader
/// clicked, whose state says when that change is drawn.
export function holdFold(toggle: HTMLElement, now = performance.now(), control?: HTMLElement): FoldAnchor {
  const span = Math.max(foldMs(toggle) + FOLD_SETTLE_MS, FOLD_HOLD_MIN_MS);
  const anchor: FoldAnchor = {
    toggle,
    top: toggle.getBoundingClientRect().top,
    until: now + span,
    span,
    latest: now + Math.max(FOLD_DRAW_WAIT_MS, span),
    pending: true,
  };
  const find = lineSelector(toggle);
  if (find) anchor.find = find;
  const from = control ? toggleState(control) : undefined;
  if (control && from !== undefined) {
    anchor.control = control;
    anchor.from = from;
    const controlFind = control === toggle ? find : lineSelector(control);
    if (controlFind) anchor.controlFind = controlFind;
  }
  const root = typeof toggle.closest === "function" ? toggle.closest(".acpmux-scroll") : null;
  if (root) anchor.root = root;
  return anchor;
}

/// The hold for a click on `toggle`: the one its press started (`pressed`, same line, still on), kept
/// at the place the line was pressed at and timed from the click, so a line that streaming moved
/// between press and release goes back to where the reader pressed it; else a new one.
export function clickFold(
  toggle: HTMLElement,
  pressed: FoldAnchor | undefined,
  now = performance.now(),
  control?: HTMLElement,
): FoldAnchor {
  const fresh = holdFold(toggle, now, control);
  if (!pressed || !foldHolding(pressed, now)) return fresh;
  if (pressed.toggle === toggle) fresh.top = pressed.top;
  // The same click's control (its press, or the click before the row's own anchored-collapse ask):
  // its state from before the click, so a change already drawn is not taken for the state it left.
  if (control && pressed.control && (pressed.control === control || pressed.toggle === toggle)) {
    fresh.control = pressed.control;
    fresh.from = pressed.from;
    if (pressed.controlFind) fresh.controlFind = pressed.controlFind;
  }
  return fresh;
}

/// Whether a wheel event is the reader scrolling the transcript: up or down, not sideways (a code
/// block's horizontal scroll keeps the hold).
export function verticalWheel(event: { deltaX: number; deltaY: number }): boolean {
  return Math.abs(event.deltaY) > Math.abs(event.deltaX);
}

/// Puts the held line back where it was clicked by moving `scroller`'s offset. False once the hold
/// is over (its time is up, or the line left the transcript), and the view is the reader's again.
export function keepFold(anchor: FoldAnchor, scroller: HTMLElement, now = performance.now()): boolean {
  const line = heldLine(anchor);
  if (!line || now > deadline(anchor)) return false;
  const moved = line.getBoundingClientRect().top - anchor.top;
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
  return anchor !== undefined && now <= deadline(anchor) && heldLine(anchor) !== undefined;
}
