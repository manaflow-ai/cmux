// The model menu's width (QuickModelColumns.tsx). By default it is as wide as the rows it shows
// (the open tab's, or a search's matches), from 28.5em up to 40em (quickModelColumns.css). A drag on its outer edge sets a width of the person's own, kept for every composer in the app and
// followed by every open page (as modelChipIcon.ts is); a double-click on the edge goes back to
// the default (Lucas 2026-11-10). Narrower than a name, the name wraps (Lawrence 2026-11-05: "cant
// see full model name").
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.acpmux.modelMenuWidth";
/// The narrowest a drag makes the menu, in px: the rail, a short model name and an effort level.
export const MODEL_MENU_MIN_WIDTH = 260;

function stored(): number | undefined {
  try {
    const value = Number(globalThis.localStorage?.getItem(STORAGE_KEY));
    return Number.isFinite(value) && value >= MODEL_MENU_MIN_WIDTH ? Math.round(value) : undefined;
  } catch {
    return undefined;
  }
}

let width = stored();
const listeners = new Set<() => void>();

/** The width the person dragged the model menu to, in px; undefined: the default width. */
export function modelMenuWidth(): number | undefined {
  return width;
}

/** Keeps `next` as the model menu's width in every composer; undefined goes back to the default. */
export function setModelMenuWidth(next: number | undefined) {
  const value = next === undefined ? undefined : Math.max(MODEL_MENU_MIN_WIDTH, Math.round(next));
  if (value === width) return;
  width = value;
  try {
    if (value === undefined) globalThis.localStorage?.removeItem(STORAGE_KEY);
    else globalThis.localStorage?.setItem(STORAGE_KEY, String(value));
  } catch {
    // A blocked store keeps the width for this page only.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (another chat's tab, the New Tab page) changed it.
  const changed = (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    const next = stored();
    if (next === width) return;
    width = next;
    for (const each of listeners) each();
  };
  globalThis.addEventListener?.("storage", changed);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", changed);
  };
}

export function useModelMenuWidth(): number | undefined {
  return useSyncExternalStore(subscribe, modelMenuWidth, modelMenuWidth);
}
