// The hat's top rim drags (SubagentTray.tsx): up makes its list of lines taller, down shorter, as a
// sheet's grabber does (Leo, 2026-11-12: "you have this glass rim, but you can't drag up the
// composer hat area"). Dragged up from folded, the hat opens to the height the drag reaches; dragged
// down past its last line, it folds and keeps the height it had. A press that never moves is a click on
// what the rim lies over. A double-click on the rim goes back to the default five lines.
//
// The height is the person's, one for every chat: it is kept in memory while a drag runs, so every
// hat on the page follows it, and written to localStorage when the drag ends, so it survives a reload.
// It caps the list (its `max-height`), never pads it: a hat with two lines stays two lines tall.
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.agentPane.hatListHeight";

/// The shortest list a drag leaves open: one line. Below half of it the drag folds the hat instead.
export const HAT_MIN_HEIGHT = 28;
/// The tallest list as a share of the window, so the transcript always keeps most of the pane.
export const HAT_MAX_SHARE = 0.7;
/// How far a press on the rim moves before it is a drag: a click on it never opens, folds or sizes.
export const HAT_OPEN_SLOP = 8;

/// The list height a drag asks for, kept between one line and `HAT_MAX_SHARE` of the window.
export function clampHatHeight(px: number, viewport: number): number {
  const max = Math.max(HAT_MIN_HEIGHT, Math.floor(viewport * HAT_MAX_SHARE));
  return Math.round(Math.min(Math.max(px, HAT_MIN_HEIGHT), max));
}

/// What a drag from `start` (the list's height when it began, 0 folded) does after the pointer
/// moved `grown` px up (negative: down): fold the hat, keep it folded, or size its list.
export function hatDrag(
  start: number,
  grown: number,
  viewport: number,
): { kind: "fold" } | { kind: "rest" } | { kind: "size"; height: number } {
  // A press that wobbles a pixel or two is a click, open or folded: it sizes nothing and saves nothing.
  if (Math.abs(grown) < HAT_OPEN_SLOP) return { kind: "rest" };
  if (start === 0 && grown < 0) return { kind: "rest" };
  const wanted = start + grown;
  if (wanted < HAT_MIN_HEIGHT / 2) return { kind: "fold" };
  return { kind: "size", height: clampHatHeight(wanted, viewport) };
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
