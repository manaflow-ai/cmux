// The model menu's size (QuickModelColumns.tsx). By default its width fits the widest model name the
// person can see in any tab, Legacy ones too (naturalMenuWidth), so it does not change width from tab
// to tab, and its height fits its rows up to a cap (quickModelColumns.css). A drag on its outer edge
// sets a width of the person's own, and a drag on its edge away from the chip a height (standup
// 2026-11-12: "resize vertical height"); each is kept for every composer in the app and followed by
// every open page (as modelChipIcon.ts is); a double-click on the edge goes back to the default
// (Lucas 2026-11-10). Narrower than a name, the name wraps (Lawrence 2026-11-05: "cant see full model
// name").
import { useSyncExternalStore } from "react";

/// The narrowest a drag makes the menu, in px: the rail, a short model name and an effort level.
export const MODEL_MENU_MIN_WIDTH = 260;
/// The shortest a drag makes the menu, in px: the search row and a few rows under it.
export const MODEL_MENU_MIN_HEIGHT = 160;

/// One size the person dragged the menu to, in px, kept in local storage under `key`. The sizes kept
/// under `retired` keys (an older default's) are dropped once, so an update that changes the default
/// starts everyone from it; a drag after that is kept as before (Lucas 2026-11-12).
export function sizeStore(key: string, least: number, retired: readonly string[] = []) {
  try {
    for (const old of retired) globalThis.localStorage?.removeItem(old);
  } catch {
    // A blocked store has nothing to drop.
  }
  const stored = (): number | undefined => {
    try {
      const value = Number(globalThis.localStorage?.getItem(key));
      return Number.isFinite(value) && value >= least ? Math.round(value) : undefined;
    } catch {
      return undefined;
    }
  };
  let size = stored();
  const listeners = new Set<() => void>();
  const get = (): number | undefined => size;
  const set = (next: number | undefined) => {
    const value = next === undefined ? undefined : Math.max(least, Math.round(next));
    if (value === size) return;
    size = value;
    try {
      if (value === undefined) globalThis.localStorage?.removeItem(key);
      else globalThis.localStorage?.setItem(key, String(value));
    } catch {
      // A blocked store keeps the size for this page only.
    }
    for (const listener of listeners) listener();
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    // Another page (another chat's tab, the New Tab page) changed it.
    const changed = (event: StorageEvent) => {
      if (event.key !== key && event.key !== null) return;
      const next = stored();
      if (next === size) return;
      size = next;
      for (const each of listeners) each();
    };
    globalThis.addEventListener?.("storage", changed);
    return () => {
      listeners.delete(listener);
      globalThis.removeEventListener?.("storage", changed);
    };
  };
  return { get, set, subscribe };
}

// v2 (2026-11-12): the default became a fit of both columns, its height the tallest Reasoning column;
// a width dragged under the older default is dropped once. Bump the version again to reset everyone's.
const widthStore = sizeStore("cmux.acpmux.modelMenuWidth.v2", MODEL_MENU_MIN_WIDTH, ["cmux.acpmux.modelMenuWidth"]);
const heightStore = sizeStore("cmux.acpmux.modelMenuHeight.v2", MODEL_MENU_MIN_HEIGHT, ["cmux.acpmux.modelMenuHeight"]);

/** The width the person dragged the model menu to, in px; undefined: the default width. */
export function modelMenuWidth(): number | undefined {
  return widthStore.get();
}

/** Keeps `next` as the model menu's width in every composer; undefined goes back to the default. */
export function setModelMenuWidth(next: number | undefined) {
  widthStore.set(next);
}

/** The model menu's own width, re-rendering when a drag here or on another page changes it. */
export function useModelMenuWidth(): number | undefined {
  return useSyncExternalStore(widthStore.subscribe, widthStore.get, widthStore.get);
}

/** The height the person dragged the model menu to, in px; undefined: the default height. */
export function modelMenuHeight(): number | undefined {
  return heightStore.get();
}

/** Keeps `next` as the model menu's height in every composer; undefined goes back to the default. */
export function setModelMenuHeight(next: number | undefined) {
  heightStore.set(next);
}

/** The model menu's own height, re-rendering when a drag here or on another page changes it. */
export function useModelMenuHeight(): number | undefined {
  return useSyncExternalStore(heightStore.subscribe, heightStore.get, heightStore.get);
}

type MeasureCanvas = { getContext(kind: "2d"): CanvasRenderingContext2D | null };
/// One canvas per document to measure text with: a canvas made in another document (another page's,
/// a closed one) may not draw.
const canvases = new WeakMap<Document, MeasureCanvas>();
function canvasOf(doc: Document): MeasureCanvas {
  let canvas = canvases.get(doc);
  if (!canvas) {
    canvas = doc.createElement("canvas");
    canvases.set(doc, canvas);
  }
  return canvas;
}

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

/// A name's width on one line, in px. A models column's names wrap when the menu is narrower than them
/// (quickModelColumns.css), so a wrapped name's box is the room it was given, not the room it needs:
/// the row's star check (QuickModelColumns markStarRooms) reads this. The box's own width without a canvas.
export function nameLineWidth(name: HTMLElement): number {
  const style = name.ownerDocument.defaultView?.getComputedStyle(name);
  const canvas = canvasOf(name.ownerDocument);
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = canvas.getContext("2d");
  } catch {
    context = null;
  }
  if (!context || !style) return name.scrollWidth;
  context.font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  return Math.max(name.scrollWidth, Math.ceil(context.measureText(name.textContent ?? "").width));
}

/// One row the effort column can show: its label and the mark after it (a level's or provider's check,
/// Fast's switch). A provider's name can run long: it is held to the column's most width and ends in
/// an ellipsis past it; a level's name and Fast always fit whole (Lucas 2026-11-12: never "Extra ...").
export type EffortLabel = { text: string; mark: "check" | "switch"; provider?: boolean };

/// The effort column's width, in px, from its measured parts: the widest level or Fast row and the
/// widest provider row (each its text, gap and mark), the room around a row (the column's border and
/// padding and the row's), the Reasoning heading's whole width, and the most a provider row may take.
/// Every level, Fast and the heading fit whole; a provider fits up to `most`.
export function fitEffortWidth(parts: {
  levels: number;
  providers: number;
  padding: number;
  head: number;
  most?: number;
}): number {
  const provider = parts.providers > 0 ? parts.providers + parts.padding : 0;
  const width = Math.max(
    parts.levels + parts.padding,
    parts.most && parts.most > 0 ? Math.min(provider, parts.most) : provider,
    parts.head,
  );
  return Math.ceil(width + 2);
}

/// The effort column's one width, in px, for every model of every tab (Lucas 2026-11-11: a width
/// across all efforts, so the column never moves as the highlight does): fitEffortWidth over `labels`,
/// read from `tune`, a rendered effort column with a level row in it, and its Reasoning heading.
/// Undefined with nothing to measure with.
export function effortColumnWidth(labels: readonly EffortLabel[], tune: HTMLElement | null | undefined) {
  // A level row, never the None note, which is drawn smaller.
  const row = tune?.querySelector<HTMLElement>(".acpmux-cols-row:not(.acpmux-cols-note)");
  const name = row?.querySelector<HTMLElement>(".acpmux-cols-name");
  const view = tune?.ownerDocument.defaultView;
  if (!tune || !row || !name || !view || labels.length === 0) return undefined;
  const canvas = canvasOf(tune.ownerDocument);
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = canvas.getContext("2d");
  } catch {
    return undefined;
  }
  if (!context) return undefined;
  const fontOf = (style: CSSStyleDeclaration) =>
    `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  context.font = fontOf(view.getComputedStyle(name));
  const style = view.getComputedStyle(row);
  const content = row.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight);
  const padding = tune.getBoundingClientRect().width - content;
  const gap = Number.parseFloat(style.columnGap) || 0;
  const check = Math.max(14, tune.querySelector(".acpmux-cols-check")?.getBoundingClientRect().width ?? 0);
  const toggle = tune.querySelector(".acpmux-cols-switch")?.getBoundingClientRect().width || 28;
  let levels = 0;
  let providers = 0;
  for (const label of labels) {
    const width = context.measureText(label.text).width + gap + (label.mark === "switch" ? toggle : check);
    if (label.provider) providers = Math.max(providers, width);
    else levels = Math.max(levels, width);
  }
  if (!(levels > 0 || providers > 0) || !(padding >= 0)) return undefined;
  // The heading sits over the column in the search row, in its own (caption) type.
  let head = 0;
  const heading = tune.parentElement?.querySelector<HTMLElement>(":scope > .acpmux-cols-tune-head");
  if (heading) {
    const headStyle = view.getComputedStyle(heading);
    context.font = fontOf(headStyle);
    head =
      context.measureText(heading.textContent ?? "").width +
      Number.parseFloat(headStyle.paddingLeft) +
      Number.parseFloat(headStyle.paddingRight) +
      (Number.parseFloat(headStyle.borderLeftWidth) || 0);
  }
  const tuneStyle = view.getComputedStyle(tune);
  const most =
    Number.parseFloat(tuneStyle.getPropertyValue("--acpmux-cols-tune-most")) * Number.parseFloat(tuneStyle.fontSize);
  return fitEffortWidth({ levels, providers, padding, head, ...(most > 0 ? { most } : {}) });
}

/// The most rows any model's effort column shows: its levels (or its None note), and a provider caption
/// and its providers where it has more than one; and whether any model shows Fast under them.
export type TuneShape = { rows: number; captions: number; fast: boolean };

/// The measured heights, in px, the menu's default height is made of: the search row the Reasoning
/// heading sits in, the line under it, the scrolling part's padding (top and bottom), one level row, one
/// provider caption, the Fast footer, and what the frame draws outside the columns (an update strip).
export type TuneMetrics = {
  head: number;
  line: number;
  padding: number;
  row: number;
  caption: number;
  foot: number;
  around: number;
};

/// The menu's default height, in px: the tallest effort column whole, from the search row to Fast, with
/// nothing to scroll and no room left over (Lucas 2026-11-12: "near perfect fit"). The models column
/// takes the same height and scrolls on its own.
export function fitMenuHeight(shape: TuneShape, metrics: TuneMetrics): number {
  return Math.ceil(
    metrics.head +
      metrics.line +
      metrics.padding +
      shape.rows * metrics.row +
      shape.captions * metrics.caption +
      (shape.fast ? metrics.foot : 0) +
      metrics.around,
  );
}

/// fitMenuHeight's metrics read from `tune`, a rendered effort column, and a level row (else a model
/// row, the same height). A part
/// the shown model does not draw (a provider caption, the Fast footer) is reckoned from the parts it
/// does draw. Undefined with nothing to measure with.
export function tuneMetrics(tune: HTMLElement | null | undefined): TuneMetrics | undefined {
  const view = tune?.ownerDocument.defaultView;
  const scroll = tune?.querySelector<HTMLElement>(":scope > .acpmux-cols-tune-scroll");
  const heading = tune?.parentElement?.querySelector<HTMLElement>(":scope > .acpmux-cols-tune-head");
  const body = tune?.parentElement;
  // A level row, else (a model with no levels shows only its None note) a model row: the same row.
  const row =
    scroll?.querySelector<HTMLElement>(".acpmux-cols-row:not(.acpmux-cols-note)") ??
    body?.querySelector<HTMLElement>(".acpmux-cols-lists [role=option].acpmux-cols-row");
  const frame = body?.parentElement;
  if (!tune || !view || !scroll || !row || !heading || !body || !frame) return undefined;
  const height = (node: Element | null | undefined) => node?.getBoundingClientRect().height ?? 0;
  const scrollStyle = view.getComputedStyle(scroll);
  const padding = Number.parseFloat(scrollStyle.paddingTop) + Number.parseFloat(scrollStyle.paddingBottom);
  const line = Number.parseFloat(view.getComputedStyle(tune).borderTopWidth) || 0;
  const rowHeight = height(row);
  if (!(rowHeight > 0)) return undefined;
  const caption = height(scroll.querySelector(".acpmux-cols-caption")) || rowHeight;
  const foot = height(tune.querySelector(":scope > .acpmux-cols-tune-foot")) || rowHeight + padding + line;
  return {
    head: height(heading),
    line,
    padding,
    row: rowHeight,
    caption,
    foot,
    around: Math.max(0, height(frame) - height(body)),
  };
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
  // The rail and models sit in one grid (.acpmux-cols-lists), beside the effort column in the body's.
  const lists = list?.parentElement;
  const body = lists?.parentElement;
  if (!list || !name || !lists || !body || names.length === 0) return undefined;
  const doc = list.ownerDocument;
  const canvas = canvasOf(doc);
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
  const view = doc.defaultView;
  const columns = (view?.getComputedStyle(lists).gridTemplateColumns ?? "").split(" ");
  const sides = (view?.getComputedStyle(body).gridTemplateColumns ?? "").split(" ");
  const listWidth = list.getBoundingClientRect().width;
  const room = roomAround(name, listWidth);
  if (!(longest > 0) || !(listWidth > 0) || columns.length < 2 || sides.length < 2) return undefined;
  const [rail, models] = columns.map((column) => Number.parseFloat(column));
  const drawn = Number.parseFloat(sides[1] ?? "");
  if (!rail || !models || !drawn) return undefined;
  return Math.ceil(rail + Math.ceil(longest + room + 2) + (settings ?? drawn));
}
