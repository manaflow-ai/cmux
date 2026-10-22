// A "Worked for" line (or a subagent group) the reader opens or closes adds or removes whole virtual
// rows, so the shared fold (fold.ts), which sizes one body inside a row, cannot play it. This file
// gives those toggles the same motion, on the same token (`--cv-fold-duration`) and in the same
// time:
// - rows below the line slide from where they were drawn to their new place (a FLIP on `translate`,
//   which never changes layout, so nothing the virtualizer measures moves);
// - opening, the rows it reveals fade in;
// - closing, a drawn copy of the rows it hides fades out under the rows sliding up over it.
// The line itself and every row above it never move here: VirtualTranscript holds the clicked line
// in place (foldAnchor.ts) by moving the offset, and the motion reads each row's place below the
// line, so it plays on top of that hold and a reader who scrolls meanwhile scrolls every row alike. Reduce Motion, the host's animation
// switches (`data-agent-motion="off"`, a 0 ms token) and a page with no Web Animations open and
// close at once: nothing here runs.
import { foldMotion, foldMs } from "./fold";
import { FOLD_SETTLE_MS } from "./foldAnchor";

/// The fold's state on the thread while it plays: "open" or "close" (the CSS and tests read it).
export const TURN_FOLD_ATTR = "data-turn-fold";
/// A drawn copy of a row a close hides, fading out where the row was (conversation.css).
export const TURN_FOLD_GHOST = "acpmux-row--fold-ghost";

/// A row as the transcript places it: its id and top (layout px), by index.
export type PlacedRows = {
  count: number;
  /// The id of the row at `index` (read on demand: nothing here copies the whole transcript per render).
  idAt: (index: number) => string | undefined;
  tops: ArrayLike<number>;
};

export type TurnFold = {
  /// The toggled row, and its index when last placed (a hint: rows stream in only below it).
  id: string;
  at: number;
  opening: boolean;
  sessionId?: string;
  ms: number;
  /// When the motion started and when it stops (performance.now()).
  start: number;
  until: number;
  /// The rows as placed at the toggle, for a row that mounts mid-fold: where it was then.
  startRows: PlacedRows;
  startAt: number;
  /// `startRows`' indexes by id, made the first time a row needs one.
  startIndex?: Map<string, number>;
  /// How far below the line each mounted row below it was drawn, as last placed.
  tops: Map<string, number>;
  /// The rows below the line mounted at the toggle: a copy of each one that leaves the mounted rows
  /// stays drawn while it would still be on its way (a closed row fading out, a pushed one sliding).
  copies: Map<string, HTMLElement>;
  /// Rows already faded in.
  faded: Set<string>;
  /// The animations this fold started, so another toggle can settle them first.
  animations: Set<Animation>;
  /// Each row's slide now: a later pass replaces it, so a row never runs two at once.
  slides: Map<HTMLElement, Animation>;
};

/// The fold each thread plays now: a fold's own timer ends only that fold, not a later one.
const playing = new WeakMap<HTMLElement, TurnFold>();

/// The mounted rows of `thread` (its `.acpmux-row` articles), each with its index.
function mountedRows(thread: HTMLElement): { node: HTMLElement; id: string; index: number }[] {
  const out: { node: HTMLElement; id: string; index: number }[] = [];
  for (const node of thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")) {
    const index = Number(node.getAttribute("aria-posinset")) - 1;
    if (index >= 0) out.push({ node, id: node.dataset.rowId!, index });
  }
  return out;
}

/// Where row `id` is in `placed`: at `hint` when it is still there, else found.
function indexOfRow(placed: PlacedRows, id: string, hint = -1): number {
  if (hint >= 0 && placed.idAt(hint) === id) return hint;
  for (let index = 0; index < placed.count; index += 1) if (placed.idAt(index) === id) return index;
  return -1;
}

/// How far below the line row `id` was placed at the toggle; undefined for a row the toggle added.
function startTop(fold: TurnFold, id: string): number | undefined {
  if (!fold.startIndex) {
    fold.startIndex = new Map();
    for (let index = fold.startAt + 1; index < fold.startRows.count; index += 1)
      fold.startIndex.set(fold.startRows.idAt(index)!, index);
  }
  const index = fold.startIndex.get(id);
  return index === undefined ? undefined : fold.startRows.tops[index]! - fold.startRows.tops[fold.startAt]!;
}

/// A copy of `row` that can sit in the thread for a moment: no ids, nothing focusable or found.
function ghostOf(row: HTMLElement): HTMLElement {
  const copy = row.cloneNode(true) as HTMLElement;
  for (const node of [copy, ...copy.querySelectorAll<HTMLElement>("[id], [data-row-id], [tabindex]")]) {
    node.removeAttribute("id");
    node.removeAttribute("data-row-id");
    node.removeAttribute("tabindex");
  }
  for (const name of ["aria-posinset", "aria-setsize", "aria-label", "aria-current", "data-transcript-active"])
    copy.removeAttribute(name);
  copy.classList.remove("acpmux-row--enter", "acpmux-row--older");
  copy.classList.add(TURN_FOLD_GHOST);
  copy.setAttribute("aria-hidden", "true");
  copy.setAttribute("inert", "");
  return copy;
}

/// How far a sliding row is drawn below its place now (its animated `translate`), in px.
function drawnShift(node: HTMLElement): number {
  const value = node.ownerDocument.defaultView?.getComputedStyle(node).translate ?? "";
  const y = parseFloat(value.split(" ")[1] ?? "");
  return Number.isFinite(y) ? y : 0;
}

/// Starts the fold of row `id` the reader toggled, or undefined when it applies at once. `opening`:
/// the row was closed. Reads the rows as they are drawn now, before the toggle's render.
export function startTurnFold(
  thread: HTMLElement | null,
  id: string,
  opening: boolean,
  placed: PlacedRows,
  sessionId: string | undefined,
  now = performance.now(),
): TurnFold | undefined {
  const ms = foldMs(thread);
  if (!thread || ms <= 0) return undefined;
  const at = indexOfRow(placed, id);
  if (at < 0) return undefined;
  const tops = new Map<string, number>();
  const copies = new Map<string, HTMLElement>();
  for (const row of mountedRows(thread)) {
    if (row.index <= at || placed.idAt(row.index) !== row.id) continue;
    tops.set(row.id, placed.tops[row.index]! - placed.tops[at]!);
    copies.set(row.id, row.node);
  }
  thread.setAttribute(TURN_FOLD_ATTR, opening ? "open" : "close");
  const fold: TurnFold = {
    id,
    at,
    opening,
    sessionId,
    ms,
    start: now,
    until: now + ms + FOLD_SETTLE_MS,
    startRows: { ...placed, tops: Float64Array.from(placed.tops as ArrayLike<number>) },
    startAt: at,
    tops,
    copies,
    faded: new Set(),
    animations: new Set(),
    slides: new Map(),
  };
  playing.set(thread, fold);
  // The state goes when the fold is over even if nothing renders the transcript again by then.
  setTimeout(() => endTurnFold(thread, fold), ms + FOLD_SETTLE_MS);
  return fold;
}

/// Ends `fold`: the thread's state attribute goes. Animations already running finish on their own.
export function endTurnFold(thread: HTMLElement | null, fold: TurnFold | undefined): void {
  if (!fold || !thread || playing.get(thread) !== fold) return;
  playing.delete(thread);
  thread.removeAttribute(TURN_FOLD_ATTR);
}

/// Ends `fold` at once, drawn where it lands: its animations finish and the copies of rows it hid go
/// now. Before another toggle measures its line, and when the chat changes.
export function settleTurnFold(thread: HTMLElement | null, fold: TurnFold | undefined, ghosts: Set<HTMLElement>): void {
  if (!fold) return;
  fold.until = 0;
  fold.copies.clear();
  for (const animation of fold.animations) animation.finish();
  fold.animations.clear();
  fold.slides.clear();
  for (const ghost of ghosts) ghost.remove();
  ghosts.clear();
  endTurnFold(thread, fold);
}

/// One placement pass of `fold` after the rows were placed again: rows below the line slide from
/// where they were drawn, rows it revealed fade in, and copies of rows that left fade out (hidden)
/// or slide on (pushed past the mounted rows). A row that mounts mid-fold joins the motion where the
/// rows around it are. False once the fold is over (its time is up, the line is gone, or another
/// chat shows).
export function playTurnFold(
  fold: TurnFold,
  thread: HTMLElement,
  placed: PlacedRows,
  sessionId: string | undefined,
  ghosts: Set<HTMLElement>,
  now = performance.now(),
): boolean {
  if (now > fold.until || fold.sessionId !== sessionId) return false;
  const at = indexOfRow(placed, fold.id, fold.at);
  if (at < 0) return false;
  fold.at = at;
  const easing = foldMotion.easing(thread);
  // Every animation plays on the fold's own clock: one that starts later starts part way through.
  const timing = { duration: fold.ms, delay: Math.min(0, fold.start - now), easing };
  const rows = mountedRows(thread).filter((row) => row.index > at && placed.idAt(row.index) === row.id);
  const mounted = new Set(rows.map((row) => row.id));
  // Rows that left the mounted rows: until the toggle's render lands (a scroll's pass can come
  // first), every one is still there.
  const left = [...fold.copies.keys()].filter((id) => !mounted.has(id));
  if (left.length > 0) {
    let index: Map<string, number> | undefined;
    const below = rows[0]?.node ?? null;
    for (const id of left) {
      const ghost = ghostOf(fold.copies.get(id)!);
      fold.copies.delete(id);
      index ??= new Map(
        Array.from({ length: placed.count - at - 1 }, (_, step) => [placed.idAt(at + 1 + step)!, at + 1 + step]),
      );
      const place = index.get(id);
      const was = fold.tops.get(id);
      // Still a row, past the mounted ones: it slides on to its place. Gone: it fades out under the
      // rows sliding over it, over the whole fold (a shorter fade left a blank band behind).
      const keyframes =
        place !== undefined && was !== undefined
          ? [{ translate: "0 0" }, { translate: `0 ${placed.tops[place]! - placed.tops[at]! - was}px` }]
          : [{ opacity: 1 }, { opacity: 0 }];
      thread.insertBefore(ghost, below);
      ghosts.add(ghost);
      const drop = () => {
        ghosts.delete(ghost);
        ghost.remove();
      };
      const motion = ghost.animate(keyframes, { ...timing, fill: "forwards" });
      fold.animations.add(motion);
      motion.onfinish = drop;
      motion.oncancel = drop;
      // A hidden page suspends its animations: the copy never outlasts the fold.
      setTimeout(drop, fold.until - now);
    }
  }
  for (const row of rows) {
    const top = placed.tops[row.index]! - placed.tops[at]!;
    const was = fold.tops.get(row.id);
    fold.tops.set(row.id, top);
    const from = was ?? startTop(fold, row.id);
    if (from === undefined) {
      // A row the open revealed: it fades in where it lands.
      if (fold.opening && !fold.faded.has(row.id)) {
        fold.faded.add(row.id);
        fold.animations.add(row.node.animate([{ opacity: 0 }, { opacity: 1 }], timing));
      }
      continue;
    }
    const delta = from - top;
    if (Math.abs(delta) < 0.5) continue;
    // A pass that moves a row still sliding takes over from where it is drawn now, for the time left.
    const last = fold.slides.get(row.node);
    const sliding = last?.playState === "running" ? last : undefined;
    const drawn = sliding ? drawnShift(row.node) : 0;
    sliding?.cancel();
    if (sliding) fold.animations.delete(sliding);
    const slide = sliding
      ? row.node.animate([{ translate: `0 ${delta + drawn}px` }, { translate: "0 0" }], {
          duration: Math.max(1, fold.until - FOLD_SETTLE_MS - now),
          easing,
        })
      : row.node.animate(
          [{ translate: `0 ${delta}px` }, { translate: "0 0" }],
          was === undefined ? timing : { duration: fold.ms, easing },
        );
    fold.slides.set(row.node, slide);
    fold.animations.add(slide);
  }
  return true;
}
