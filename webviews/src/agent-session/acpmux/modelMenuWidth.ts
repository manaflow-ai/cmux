// The model menu's width (QuickModelColumns.tsx). By default it fits the widest model name the person
// can see in any tab, Legacy ones too (naturalMenuWidth), so it does not change width from tab to tab.
// A drag on its outer edge sets a width of the person's own, kept for every composer in the app and
// followed by every open page (as modelChipIcon.ts is); a double-click on the edge goes back to
// the default. Narrower than a name, the name ends in an ellipsis (Lucas 2026-11-10).
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

/// A model row's name in a rendered models column: a plain row first (no tag, no used mark, not a
/// note), so the room around the name is the row's own padding and marks only.
function measuredName(list: HTMLElement | null | undefined): HTMLElement | null {
  if (!list) return null;
  return (
    list.querySelector<HTMLElement>(
      ".acpmux-cols-row:not(.acpmux-cols-note, [data-star-cover]):not(:has(.acpmux-cols-tag, .acpmux-used-mark, .acpmux-used-caption)) > .acpmux-cols-name",
    ) ?? list.querySelector<HTMLElement>(".acpmux-cols-row:not(.acpmux-cols-note, [data-star-cover]) .acpmux-cols-name")
  );
}

/// The room a models column takes around a row's name, in px: the column's and the row's padding, and every mark
/// that stands in the row's flow (a check at least its 14 px box, so an empty check keeps the chosen row's room)
/// with the gaps before them. Read from the row, not from the name's width, since a look may keep the name at its
/// own width (the inline check).
function roomAround(name: HTMLElement, listWidth: number): number {
  const row = name.closest<HTMLElement>(".acpmux-cols-row") ?? name;
  const view = row.ownerDocument.defaultView;
  const style = view?.getComputedStyle(row);
  if (!view || !style) return listWidth - name.getBoundingClientRect().width;
  const content = row.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight);
  const gap = Number.parseFloat(style.columnGap) || 0;
  let marks = 0;
  for (const child of row.children) {
    if (child === name || child.contains(name)) continue;
    const childStyle = view.getComputedStyle(child);
    if (childStyle.position === "absolute" || childStyle.display === "none") continue;
    const width = child.getBoundingClientRect().width;
    marks += gap + (child.classList.contains("acpmux-cols-check") ? Math.max(width, 14) : width);
  }
  return listWidth - content + marks;
}

/// The font a models column draws its names in ("" before it has a row): part of the default width's
/// key, so a density, Text Size or Interface Font change measures again.
export function menuNameFont(list: HTMLElement | null): string {
  const name = measuredName(list);
  const style = name && name.ownerDocument.defaultView?.getComputedStyle(name);
  return style ? `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}` : "";
}

/// One row the effort column can show: its label and the mark after it (a level's or provider's check,
/// Fast's switch).
export type EffortLabel = { text: string; mark: "check" | "switch" };

/// The effort column's one width, in px, for every model of every tab (Lucas 2026-11-11: a width
/// across all efforts, so the column never moves as the highlight does): the widest of `labels` with
/// its mark, the gap before it and the column's and row's padding, read from `tune`, a rendered effort
/// column with a row in it. quickModelColumns.css caps it (`--acpmux-cols-tune-most`). Undefined
/// with nothing to measure with.
export function effortColumnWidth(labels: readonly EffortLabel[], tune: HTMLElement | null | undefined) {
  // A level row, never the None note, which is drawn smaller.
  const row = tune?.querySelector<HTMLElement>(".acpmux-cols-row:not(.acpmux-cols-note)");
  const name = row?.querySelector<HTMLElement>(".acpmux-cols-name");
  const view = tune?.ownerDocument.defaultView;
  if (!tune || !row || !name || !view || labels.length === 0) return undefined;
  canvas ??= tune.ownerDocument.createElement("canvas");
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = canvas.getContext("2d");
  } catch {
    return undefined;
  }
  if (!context) return undefined;
  const font = view.getComputedStyle(name);
  context.font = `${font.fontStyle} ${font.fontWeight} ${font.fontSize} ${font.fontFamily}`;
  const style = view.getComputedStyle(row);
  const content = row.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight);
  const padding = tune.getBoundingClientRect().width - content;
  const gap = Number.parseFloat(style.columnGap) || 0;
  const check = Math.max(14, tune.querySelector(".acpmux-cols-check")?.getBoundingClientRect().width ?? 0);
  const toggle = tune.querySelector(".acpmux-cols-switch")?.getBoundingClientRect().width || 28;
  let widest = 0;
  for (const label of labels)
    widest = Math.max(widest, context.measureText(label.text).width + gap + (label.mark === "switch" ? toggle : check));
  if (!(widest > 0) || !(padding >= 0)) return undefined;
  const tuneStyle = view.getComputedStyle(tune);
  const most =
    Number.parseFloat(tuneStyle.getPropertyValue("--acpmux-cols-tune-most")) * Number.parseFloat(tuneStyle.fontSize);
  const width = Math.ceil(widest + padding + 2);
  return most > 0 ? Math.min(width, Math.ceil(most)) : width;
}

/// The menu's default width, in px: the rail, a models column that fits the longest of `names` on
/// one line, then the effort column at `settings` (effortColumnWidth), else at its drawn width.
/// `list` is a rendered models column with a
/// model row in it, which gives the row's font and the room a row takes around its name (padding and
/// the star and check marks). Undefined when there is nothing to measure with (no row, no canvas).
export function naturalMenuWidth(
  names: readonly string[],
  list: HTMLElement | null,
  settings?: number,
): number | undefined {
  const name = measuredName(list);
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
  const font = menuNameFont(list);
  if (!font) return undefined;
  context.font = font;
  let longest = 0;
  for (const each of names) longest = Math.max(longest, context.measureText(each).width);
  const columns = (doc.defaultView?.getComputedStyle(body).gridTemplateColumns ?? "").split(" ");
  const listWidth = list.getBoundingClientRect().width;
  const room = roomAround(name, listWidth);
  if (!(longest > 0) || !(listWidth > 0) || columns.length < 3) return undefined;
  const [rail, models, drawn] = columns.map((column) => Number.parseFloat(column));
  if (!rail || !models || !drawn) return undefined;
  return Math.ceil(rail + Math.ceil(longest + room + 2) + (settings ?? drawn));
}
