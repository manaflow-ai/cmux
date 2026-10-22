// A "Worked for" line (or a subagent group) the reader opens or closes adds or removes whole virtual
// rows, so the shared fold (fold.ts), which sizes one body inside a row, cannot play it. This file
// gives those toggles the same motion, on the same token (`--cv-fold-duration`) and in the same
// time:
// - rows below the line slide from where they were drawn to their new place (a FLIP on `translate`,
//   which never changes layout, so nothing the virtualizer measures moves);
// - opening, the rows it reveals fade in;
// - closing, a drawn copy of the rows it hides fades out under the rows sliding up over it.
// The line itself and every row above it never move here: VirtualTranscript holds the clicked line
// in place (foldAnchor.ts) by moving the offset, and the motion reads each row's place in the view
// (its top less the offset), so it plays on top of that hold. Reduce Motion, the host's animation
// switches (`data-agent-motion="off"`, a 0 ms token) and a page with no Web Animations open and
// close at once: nothing here runs.
import { cssTimeMs, foldMotion, foldMs } from "./fold";
import { FOLD_SETTLE_MS } from "./foldAnchor";

/// The fold's state on the thread while it plays: "open" or "close" (the CSS and tests read it).
export const TURN_FOLD_ATTR = "data-turn-fold";
/// A drawn copy of a row a close hides, fading out where the row was (conversation.css).
export const TURN_FOLD_GHOST = "acpmux-row--fold-ghost";
/// The fade-out token (`--agent-motion-out`), and the share of the fold it takes with no host.
const FADE_OUT_VAR = "--agent-motion-out";

/// A row as the transcript places it: its id and top (layout px), by index.
export type PlacedRows = {
  ids: readonly string[];
  tops: readonly number[];
  /// How far the rows are drawn below their places (VirtualTranscript `lift`) less the offset.
  shift: number;
};

export type TurnFold = {
  /// The toggled row.
  id: string;
  opening: boolean;
  sessionId?: string;
  ms: number;
  /// When the motion stops (performance.now()).
  until: number;
  /// Where each mounted row below the line was drawn in the view, as last placed.
  tops: Map<string, number>;
  /// The rows there were before the toggle.
  before: Set<string>;
  /// How far rows below the line moved, for one that mounts mid-fold with no place of its own yet.
  moved?: number;
  /// Closing: copies of the mounted rows below the line, to fade out the ones that leave.
  copies?: Map<string, HTMLElement>;
  /// Rows already faded in.
  faded: Set<string>;
};

/// The mounted rows of `thread` (its `.acpmux-row` articles), each with its index.
function mountedRows(thread: HTMLElement): { node: HTMLElement; id: string; index: number }[] {
  const out: { node: HTMLElement; id: string; index: number }[] = [];
  for (const node of thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row[data-row-id]")) {
    const index = Number(node.getAttribute("aria-posinset")) - 1;
    if (index >= 0) out.push({ node, id: node.dataset.rowId!, index });
  }
  return out;
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
  const at = placed.ids.indexOf(id);
  if (at < 0) return undefined;
  const tops = new Map<string, number>();
  const copies = opening ? undefined : new Map<string, HTMLElement>();
  for (const row of mountedRows(thread)) {
    if (row.index <= at || placed.ids[row.index] !== row.id) continue;
    tops.set(row.id, placed.tops[row.index]! + placed.shift);
    copies?.set(row.id, row.node);
  }
  thread.setAttribute(TURN_FOLD_ATTR, opening ? "open" : "close");
  return {
    id,
    opening,
    sessionId,
    ms,
    until: now + ms + FOLD_SETTLE_MS,
    tops,
    before: new Set(placed.ids),
    copies,
    faded: new Set(),
  };
}

/// Ends `fold`: the thread's state attribute goes. Animations already running finish on their own.
export function endTurnFold(thread: HTMLElement | null, fold: TurnFold | undefined): void {
  if (fold && thread?.getAttribute(TURN_FOLD_ATTR) === (fold.opening ? "open" : "close"))
    thread.removeAttribute(TURN_FOLD_ATTR);
}

/// One placement pass of `fold` after the rows were placed again: rows below the line slide from
/// where they were drawn, rows it revealed fade in, and copies of rows it hid fade out. False once
/// the fold is over (its time is up, the line is gone, or another chat shows).
export function playTurnFold(
  fold: TurnFold,
  thread: HTMLElement,
  placed: PlacedRows,
  sessionId: string | undefined,
  ghosts: Set<HTMLElement>,
  now = performance.now(),
): boolean {
  if (now > fold.until || fold.sessionId !== sessionId) return false;
  const at = placed.ids.indexOf(fold.id);
  if (at < 0) return false;
  const easing = foldMotion.easing(thread);
  const rows = mountedRows(thread).filter((row) => row.index > at && placed.ids[row.index] === row.id);
  // The rows a close hid: a copy of each fades out where it was drawn, under the rows that slide up.
  // Until the toggle's render lands (a scroll's pass can come first), every copy's row is still there.
  const present = fold.copies && new Set(placed.ids);
  if (fold.copies && [...fold.copies.keys()].some((id) => !present!.has(id))) {
    const out = cssTimeMs(
      thread.ownerDocument.defaultView?.getComputedStyle(thread).getPropertyValue(FADE_OUT_VAR) ?? "",
    );
    const fadeMs = Math.min(fold.ms, out && out > 0 ? out : fold.ms / 2);
    const below = rows[0]?.node ?? null;
    for (const [id, row] of fold.copies) {
      if (present!.has(id)) continue;
      const ghost = ghostOf(row);
      thread.insertBefore(ghost, below);
      ghosts.add(ghost);
      const drop = () => {
        ghosts.delete(ghost);
        ghost.remove();
      };
      const fade = ghost.animate([{ opacity: 1 }, { opacity: 0 }], { duration: fadeMs, easing, fill: "forwards" });
      fade.onfinish = drop;
      fade.oncancel = drop;
      // A hidden page suspends its animations: the copy never outlasts the fold.
      setTimeout(drop, fold.ms + FOLD_SETTLE_MS);
    }
    fold.copies = undefined;
  }
  for (const row of rows) {
    const top = placed.tops[row.index]! + placed.shift;
    const was = fold.tops.get(row.id);
    fold.tops.set(row.id, top);
    if (was === undefined && !fold.before.has(row.id)) {
      // A row the open revealed: it fades in where it lands.
      if (fold.opening && !fold.faded.has(row.id)) {
        fold.faded.add(row.id);
        row.node.animate([{ opacity: 0 }, { opacity: 1 }], { duration: fold.ms, easing });
      }
      continue;
    }
    // A row below that mounts mid-fold slides with the rows around it.
    const delta = was === undefined ? (fold.moved ?? 0) : was - top;
    if (Math.abs(delta) < 0.5) continue;
    if (was !== undefined) fold.moved = delta;
    // Stacked (`composite: "add"`): a pass that moves the row again starts from where it is drawn.
    row.node.animate([{ translate: `0 ${delta}px` }, { translate: "0 0" }], {
      duration: fold.ms,
      easing,
      composite: "add",
    });
  }
  return true;
}
