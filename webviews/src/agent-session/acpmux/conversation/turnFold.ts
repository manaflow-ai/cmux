// A "Worked for" line (or a subagent group) adds or removes whole virtual rows, which the shared fold
// (fold.ts) cannot size. This file plays those toggles on the same token (`--cv-fold-duration`):
// - rows below the line slide from where they were drawn to their new place (a FLIP on `translate`,
//   which never changes layout, so nothing the virtualizer measures moves);
// - opening, the rows it reveals fade in;
// - closing, a drawn copy of the rows it hides fades out under the rows sliding up over it.
// The line and the rows above it never move here: VirtualTranscript holds the line (foldAnchor.ts)
// and the motion reads places relative to it. Reduce Motion, `data-agent-motion="off"`, a 0 ms token
// or no Web Animations: the toggle applies at once and nothing here runs.
//
// A pass runs only when the rows below the line are placed again (watchTurnFold): a row element
// mounts or unmounts, or a row's placement (`style`, its index) changes. A token streamed into a row
// changes neither, so streaming never runs one. The watcher stops when the fold ends: its timer, the
// next toggle, another chat, or the transcript unmounting.
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

/// A row element the fold moves: where it is placed below the line, and how it plays.
type Moving = {
  id: string;
  /// Its place below the line, as last placed.
  top: number;
  /// How far above or below that place it starts (where the row was drawn at the toggle).
  delta: number;
  /// A row the open revealed: it fades in.
  reveal: boolean;
  animations: Animation[];
};

export type TurnFold = {
  /// The toggled row, and its index when last placed (a hint: rows stream in only below it).
  id: string;
  at: number;
  opening: boolean;
  sessionId?: string;
  ms: number;
  /// When the motion started and when it stops (performance.now()). Every animation runs on this
  /// one clock, so an element that mounts mid-fold starts part way, in step with the rest.
  start: number;
  until: number;
  /// The rows as placed at the toggle: where any row below the line was then, mounted or not.
  startRows: PlacedRows;
  startAt: number;
  /// `startRows`' indexes by id, made the first time a row needs one.
  startIndex?: Map<string, number>;
  /// Every row element below the line the fold has drawn, while it is mounted.
  moving: Map<HTMLElement, Moving>;
  /// The drawn copy of a row that left the mounted rows mid-fold, by row id.
  copies: Map<string, HTMLElement>;
  /// The animations this fold started, so another toggle can settle them first.
  animations: Set<Animation>;
  /// Stops the watcher (watchTurnFold) and tells the transcript the fold is over; once, at its end.
  stop?: () => void;
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
  const moving = new Map<HTMLElement, Moving>();
  for (const row of mountedRows(thread)) {
    if (row.index <= at || placed.idAt(row.index) !== row.id) continue;
    const top = placed.tops[row.index]! - placed.tops[at]!;
    moving.set(row.node, { id: row.id, top, delta: 0, reveal: false, animations: [] });
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
    moving,
    copies: new Map(),
    animations: new Set(),
  };
  playing.set(thread, fold);
  // The state goes when the fold is over even if nothing renders the transcript again by then.
  setTimeout(() => endTurnFold(thread, fold), ms + FOLD_SETTLE_MS);
  return fold;
}

/// Ends `fold`: its watcher stops, the thread's state attribute goes, and it lets go of every row it
/// tracked. Running animations finish on their own; copies drop themselves when theirs end.
export function endTurnFold(thread: HTMLElement | null, fold: TurnFold | undefined): void {
  if (!fold) return;
  const stop = fold.stop;
  fold.stop = undefined;
  stop?.();
  fold.until = 0;
  fold.moving.clear();
  fold.animations.clear();
  fold.startIndex = undefined;
  fold.startRows = { count: 0, idAt: () => undefined, tops: [] };
  if (!thread || playing.get(thread) !== fold) return;
  playing.delete(thread);
  thread.removeAttribute(TURN_FOLD_ATTR);
}

/// Ends `fold` at once, drawn where it lands: its animations finish and the copies of rows it hid go
/// now. Before another toggle measures its line, and when the chat changes.
export function settleTurnFold(thread: HTMLElement | null, fold: TurnFold | undefined, ghosts: Set<HTMLElement>): void {
  if (!fold) return;
  fold.until = 0;
  for (const animation of fold.animations) animation.finish();
  fold.animations.clear();
  fold.moving.clear();
  fold.copies.clear();
  for (const ghost of ghosts) ghost.remove();
  ghosts.clear();
  endTurnFold(thread, fold);
}

/// One pass of `fold` after the rows were placed again. Each row below the line slides, on the
/// fold's clock, from where it was drawn at the toggle to its place, or fades in when the open
/// revealed it; one that mounts mid-fold joins part way, and one that leaves leaves a drawn copy that
/// goes on (a row the close hid fades out). False once the fold is over or another chat shows.
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
  const clock = { duration: fold.ms, delay: Math.min(0, fold.start - now), easing };
  const play = (node: HTMLElement, keyframes: Keyframe[], fill?: FillMode) => {
    const animation = node.animate(keyframes, fill ? { ...clock, fill } : clock);
    fold.animations.add(animation);
    return animation;
  };
  const all = mountedRows(thread);
  const rows = all.filter((row) => row.index > at && placed.idAt(row.index) === row.id);
  const mounted = new Set(all.map((row) => row.node));
  const mountedIds = new Set(rows.map((row) => row.id));
  for (const row of rows) {
    // The row is drawn again: its copy goes.
    const copy = fold.copies.get(row.id);
    if (copy) {
      fold.copies.delete(row.id);
      ghosts.delete(copy);
      copy.remove();
    }
    const top = placed.tops[row.index]! - placed.tops[at]!;
    const from = startTop(fold, row.id);
    const reveal = from === undefined && fold.opening;
    const delta = from === undefined ? 0 : from - top;
    const last = fold.moving.get(row.node);
    if (last && Math.abs(last.delta - delta) < 0.5 && last.reveal === reveal) {
      last.top = top;
      continue;
    }
    for (const animation of last?.animations ?? []) {
      animation.cancel();
      fold.animations.delete(animation);
    }
    const animations: Animation[] = [];
    if (Math.abs(delta) >= 0.5) animations.push(play(row.node, [{ translate: `0 ${delta}px` }, { translate: "0 0" }]));
    if (reveal) animations.push(play(row.node, [{ opacity: 0 }, { opacity: 1 }]));
    fold.moving.set(row.node, { id: row.id, top, delta, reveal, animations });
  }
  // Row elements that left the mounted rows. Only while a fold plays (its time, about a fifth of a
  // second, is the only window this runs in) and only in a pass where a row left: the rows below the
  // line are indexed once for that pass.
  let index: Map<string, number> | undefined;
  const below = rows[0]?.node ?? null;
  for (const [node, row] of fold.moving) {
    if (mounted.has(node)) continue;
    fold.moving.delete(node);
    if (mountedIds.has(row.id) || fold.copies.has(row.id)) continue;
    index ??= new Map(
      Array.from({ length: Math.max(0, placed.count - at - 1) }, (_, step) => [
        placed.idAt(at + 1 + step)!,
        at + 1 + step,
      ]),
    );
    const place = index.get(row.id);
    // Still a row, past the mounted ones: the copy slides on to its place. Gone (the close hid it):
    // it fades out where it was, under the rows sliding over it, over the whole fold (a shorter fade
    // left a blank band behind).
    const to = place === undefined ? 0 : placed.tops[place]! - placed.tops[at]! - row.top;
    const first: Keyframe = {};
    const end: Keyframe = {};
    if (Math.abs(row.delta) >= 0.5 || Math.abs(to) >= 0.5) {
      first.translate = `0 ${row.delta}px`;
      end.translate = `0 ${to}px`;
    }
    if (place === undefined) {
      first.opacity = 1;
      end.opacity = 0;
    } else if (row.reveal) {
      first.opacity = 0;
      end.opacity = 1;
    }
    if (Object.keys(first).length === 0) continue;
    const ghost = ghostOf(node);
    thread.insertBefore(ghost, below);
    ghosts.add(ghost);
    fold.copies.set(row.id, ghost);
    const drop = () => {
      ghosts.delete(ghost);
      if (fold.copies.get(row.id) === ghost) fold.copies.delete(row.id);
      ghost.remove();
    };
    const motion = play(ghost, [first, end], "forwards");
    motion.onfinish = drop;
    motion.oncancel = drop;
    // A hidden page suspends its animations: the copy never outlasts the fold.
    setTimeout(drop, Math.max(0, fold.until - now));
  }
  return true;
}

/// What a row's placement changes on its element: its offset (`style`) and its index.
const PLACED: MutationObserverInit = { attributes: true, attributeFilter: ["style", "aria-posinset"] };
const isRow = (node: Node): node is HTMLElement =>
  node.nodeType === 1 &&
  (node as Element).classList.contains("acpmux-row") &&
  (node as Element).hasAttribute("data-row-id");

/// Plays `fold` each time the rows below its line are placed again: the thread's row elements
/// mount or unmount, or a mounted row's placement changes. `read` gives the rows as placed now.
/// `done` runs once when the fold ends (its timer, a settle, or another chat); the observer stops then.
export function watchTurnFold(
  fold: TurnFold,
  thread: HTMLElement,
  read: () => { placed: PlacedRows; sessionId: string | undefined },
  ghosts: Set<HTMLElement>,
  done: () => void,
): void {
  const Observer = thread.ownerDocument.defaultView?.MutationObserver;
  if (!Observer) {
    fold.stop = done;
    return;
  }
  const observer = new Observer((records) => {
    let moved = false;
    for (const record of records) {
      // Rows are the only nodes watched for attributes.
      if (record.type === "attributes") moved = true;
      for (const node of record.addedNodes)
        if (isRow(node)) {
          observer.observe(node, PLACED);
          moved = true;
        }
      for (const node of record.removedNodes) if (isRow(node)) moved = true;
    }
    if (!moved) return;
    const now = read();
    if (!playTurnFold(fold, thread, now.placed, now.sessionId, ghosts)) settleTurnFold(thread, fold, ghosts);
  });
  observer.observe(thread, { childList: true });
  for (const node of thread.children) if (isRow(node)) observer.observe(node, PLACED);
  fold.stop = () => {
    observer.disconnect();
    done();
  };
}
