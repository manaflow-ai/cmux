// The hat's top rim drags (SubagentTray.tsx): up makes its list of lines taller, down shorter, as a
// sheet's grabber does (Leo, 2026-11-12: "you have this glass rim, but you can't drag up the
// composer hat area").
//
// Leo, 2026-11-22, on the first build: "the "halfway point" was not the halfway from 5. it was
// halfway down if there was only one row, or something like that. the vibes and ergonomics are
// completely off here. the dragging isn't properly relative accurate to the cursor, and it's just
// jumpy all over the place and doesn't have satisfying snap alongs. i also am not sure if clicking on
// the resizing area itself should necessarily hide it. it seems like possibly errant clicks could make
// it jump unnecessarily." So the drag is a sheet's:
//
// - The rim stays under the cursor, 1:1 from where it was grabbed, down to nothing and up to the last
//   line. Past the last line it gives a little and holds (a rubber band), so the rim never sits still
//   while the cursor moves on and then lags back: reversing moves it again at once.
// - Each line's bottom edge is a detent: within a few px of one the rim settles on it, so a slow
//   drag clicks from line to line.
// - On release it lands on a whole line: a line more than half shown stays, less than half goes.
//   The first line's halfway point is the fold: released above it the hat folds, keeping its height.
// - A press that never moves does nothing: no fold, no open, no size, no click passed through. A
//   double-click goes back to the default five lines.
//
// The height is the person's, one for every chat: it is kept in memory while a drag runs, so every
// hat on the page follows it, and written to localStorage when the drag ends, so it survives a reload.
// It caps the list (its `max-height`), never pads it: a hat with two lines stays two lines tall.
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.agentPane.hatListHeight";

/// One line's height, for a list whose lines cannot be measured.
export const HAT_MIN_HEIGHT = 28;
/// The tallest list as a share of the window, so the transcript always keeps most of the pane.
export const HAT_MAX_SHARE = 0.7;
/// How far a press on the rim moves before it is a drag. Small, so the rim catches the cursor almost
/// at once; a press that stays inside it is no drag and does nothing.
export const HAT_OPEN_SLOP = 3;
/// How close to a line's edge the rim settles on it while dragging.
export const HAT_DETENT = 5;
/// How far past the last line the rim gives before it holds.
export const HAT_STRETCH = 14;

/// The list height a drag asks for, kept between one line and `HAT_MAX_SHARE` of the window.
export function clampHatHeight(px: number, viewport: number): number {
  const max = Math.max(HAT_MIN_HEIGHT, Math.floor(viewport * HAT_MAX_SHARE));
  return Math.round(Math.min(Math.max(px, HAT_MIN_HEIGHT), max));
}

/// What a drag knows about the list when it is measured: its height when the drag began (0 folded),
/// the bottom edge of each line (ascending, in the same units), and the window's height.
export type HatDragFrame = { start: number; edges: readonly number[]; viewport: number };

/// The tallest the list shows: its last line's edge, or the window's cap, whichever comes first.
function top(frame: HatDragFrame): number {
  const last = frame.edges.at(-1) ?? HAT_MIN_HEIGHT;
  return Math.min(last, Math.max(HAT_MIN_HEIGHT, Math.floor(frame.viewport * HAT_MAX_SHARE)));
}

/// The list's height while the pointer is `grown` px above where it pressed (negative: below): 1:1,
/// settled on a line's edge within `HAT_DETENT`, and past the last line a short give that holds.
export function hatDragHeight(frame: HatDragFrame, grown: number): number {
  const raw = frame.start + grown;
  if (raw <= 0) return 0;
  const most = top(frame);
  if (raw > most) return Math.round(most + HAT_STRETCH * (1 - Math.exp(-(raw - most) / (HAT_STRETCH * 3))));
  for (const edge of frame.edges) if (edge <= most && Math.abs(raw - edge) <= HAT_DETENT) return edge;
  return Math.round(raw);
}

/// Where a drag lands when the pointer lets go `grown` px from where it pressed: nothing (it never
/// moved past the slop), folded (less than half the first line shown), or a whole number of lines.
/// Pulled past the last line, the cap is where the pointer went, so lines that come later show too.
export function hatDragEnd(
  frame: HatDragFrame,
  grown: number,
): { kind: "fold" } | { kind: "rest" } | { kind: "size"; height: number } {
  if (Math.abs(grown) < HAT_OPEN_SLOP) return { kind: "rest" };
  const raw = frame.start + grown;
  const edges = frame.edges.length > 0 ? frame.edges : [HAT_MIN_HEIGHT];
  const most = top(frame);
  if (raw > most) return { kind: "size", height: clampHatHeight(Math.max(raw, most), frame.viewport) };
  let landed = 0;
  let previous = 0;
  for (const edge of edges) {
    if (edge > most) break;
    if (raw > previous + (edge - previous) / 2) landed = edge;
    previous = edge;
  }
  if (landed === 0) return { kind: "fold" };
  return { kind: "size", height: clampHatHeight(landed, frame.viewport) };
}

const storage = (): Storage | undefined => {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    return undefined;
  }
};

function read(): number | undefined {
  const value = Number(storage()?.getItem(STORAGE_KEY));
  return Number.isFinite(value) && value >= HAT_MIN_HEIGHT ? value : undefined;
}

let height: number | undefined = read();
const listeners = new Set<() => void>();

/// Sets the hat's list height for every hat on the page (undefined: the default), and keeps it
/// across a reload when `keep` (a drag's end, a reset).
export function setHatHeight(next: number | undefined, keep: boolean): void {
  if (next !== height) {
    height = next;
    for (const listener of listeners) listener();
  }
  if (!keep) return;
  try {
    if (next === undefined) storage()?.removeItem(STORAGE_KEY);
    else storage()?.setItem(STORAGE_KEY, String(next));
  } catch {
    // A full or refused store keeps the height for this page only.
  }
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => height;

/// The hat's list height the person dragged to, if they did.
export const useHatHeight = (): number | undefined => useSyncExternalStore(subscribe, snapshot, snapshot);
