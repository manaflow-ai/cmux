// The model menu's width (QuickModelColumns.tsx). By default it is as wide as the longest model
// name of every harness it lists (OpenCode's, today), so it does not change width from tab to tab.
// A drag on its outer edge sets a width of the person's own, kept for every composer in the app and
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

let canvas: { getContext(kind: "2d"): CanvasRenderingContext2D | null } | undefined;

/// The menu's default width, in px: the rail, then a models column that fits the longest of
/// `names` on one line, then the settings column at the grid's share of it. `list` is a rendered
/// models column with a row in it, which gives the row's font and the room a row takes around its
/// name (padding, check, star). Undefined when there is nothing to measure with (no row, no canvas).
export function naturalMenuWidth(names: readonly string[], list: HTMLElement | null): number | undefined {
  const name = list?.querySelector<HTMLElement>(".acpmux-cols-row .acpmux-cols-name");
  const body = list?.parentElement;
  if (!list || !name || !body || names.length === 0) return undefined;
  const doc = list.ownerDocument;
  canvas ??= doc.createElement("canvas");
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = canvas.getContext("2d");
  } catch {
    return undefined;
  }
  if (!context) return undefined;
  const style = doc.defaultView?.getComputedStyle(name);
  if (!style) return undefined;
  context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  let longest = 0;
  for (const each of names) longest = Math.max(longest, context.measureText(each).width);
  const columns = (doc.defaultView?.getComputedStyle(body).gridTemplateColumns ?? "").split(" ");
  const listWidth = list.getBoundingClientRect().width;
  const room = listWidth - name.getBoundingClientRect().width;
  if (!(longest > 0) || !(listWidth > 0) || columns.length < 3) return undefined;
  const [rail, models, settings] = columns.map((column) => Number.parseFloat(column));
  if (!rail || !models || !settings) return undefined;
  const modelsColumn = Math.ceil(longest + room + 2);
  return Math.ceil(rail + modelsColumn + (modelsColumn * settings) / models);
}
