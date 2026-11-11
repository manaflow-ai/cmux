// Pure rules of the bookmarks bar (design/browser-chrome.md "Bookmarks bar"), the native
// BookmarksBarView's: which items fit, the overflow, where a drop lands, how a click opens, and the
// rows of a folder's native menu. No I/O, no DOM.
import { displayTitle } from "../../pages/bookmarks/model";
import type { Bookmark, BookmarkOp, Disposition } from "../../pages/bookmarks/types";

/** The bar's metrics in CSS px (one CSS px is one point: the host does not zoom the bar). */
export interface BarMetrics {
  /** The bar's side inset (`Metrics.paneChromeInset`). */
  inset: number;
  /** An item's and the chevron's height (`Metrics.controlHeight`). */
  itemHeight: number;
  /** Between items (`Metrics.space1`). */
  gap: number;
  /** An item's side padding (`Metrics.space4`). */
  padding: number;
  /** Icon box (`Metrics.smallIconSize`). */
  icon: number;
  /** Between the icon and the title (`Metrics.space2`). */
  iconGap: number;
  /** The widest item (`Metrics.tabMaxWidth * 0.8`). */
  maxItem: number;
}

export const COMPACT_METRICS: BarMetrics = {
  inset: 2,
  itemHeight: 24,
  gap: 2,
  padding: 8,
  icon: 12,
  iconGap: 4,
  maxItem: 160,
};

/** The bar's height: an item and `space2` (`BookmarksBarHostView.height`). */
export function barHeight(metrics: BarMetrics): number {
  return metrics.itemHeight + 4;
}

/** The width an item wants: padding, icon, gap, title, capped. `text` is the title's width. */
export function itemWidth(text: number, metrics: BarMetrics): number {
  const gap = text > 0 ? metrics.iconGap : 0;
  return Math.min(Math.ceil(metrics.padding * 2 + metrics.icon + gap + text), metrics.maxItem);
}

export interface BarLayout {
  /** How many of the bar's items show, from the start. */
  visible: number;
  /** Each shown item's left edge and width. */
  frames: Array<{ x: number; width: number }>;
  /** The chevron shows (some items did not fit). */
  overflow: boolean;
  /** The chevron's left edge. */
  chevronX: number;
}

/**
 * Lays the bar's items out left to right in `width`: what fits shows, the rest goes behind the
 * chevron, and Other Bookmarks (`otherWidth`, 0 without it) keeps the trailing end. Only the items
 * that fit get frames, so the page renders the visible window and nothing past it.
 */
export function layoutBar(
  widths: readonly number[],
  width: number,
  otherWidth: number,
  metrics: BarMetrics,
): BarLayout {
  let limit = width - metrics.inset - otherWidth;
  const total = widths.reduce((sum, item) => sum + item + metrics.gap, metrics.inset);
  if (total > limit) limit -= metrics.itemHeight;
  const frames: Array<{ x: number; width: number }> = [];
  let x = metrics.inset;
  for (const item of widths) {
    if (x + item > limit) break;
    frames.push({ x, width: item });
    x += item + metrics.gap;
  }
  return { visible: frames.length, frames, overflow: frames.length < widths.length, chevronX: x };
}

/** The slot (0...visible) nearest `x`: before the first item whose middle is right of it. */
export function insertionIndex(frames: readonly { x: number; width: number }[], x: number): number {
  const index = frames.findIndex((frame) => x < frame.x + frame.width / 2);
  return index === -1 ? frames.length : index;
}

/** The drop line's x for slot `index`, half a gap before the item it lands before. */
export function indicatorX(
  frames: readonly { x: number; width: number }[],
  index: number,
  metrics: BarMetrics,
): number {
  const first = frames[0];
  if (!first) return metrics.inset;
  const at = frames[index];
  if (at) return at.x - metrics.gap / 2;
  const last = frames[frames.length - 1] ?? first;
  return last.x + last.width + metrics.gap / 2;
}

/** A dragged bar item's final index: a drop right of its own slot counts the item itself once. */
export function finalIndex(current: number, slot: number): number {
  return current !== -1 && slot > current ? slot - 1 : slot;
}

/** The move of a bar item to its final `index` on the bar, or null when it would not move. */
export function moveOnBar(items: readonly Bookmark[], id: string, slot: number): BookmarkOp | null {
  const current = items.findIndex((item) => item.id === id);
  const index = finalIndex(current, slot);
  if (current === index) return null;
  return { op: "move", bookmark: id, parent: "bar", index };
}

/** A link dropped on the bar at `index`. */
export function createOnBar(profile: string, url: string, title: string, index: number): BookmarkOp {
  return {
    op: "create",
    id: null,
    browser_profile_id: profile,
    parent: "bar",
    index,
    kind: "url",
    title,
    url,
    favicon_key: null,
    source_key: null,
    created_ms: null,
  };
}

/** The link of a drop: the first `text/uri-list` line that is not a comment, with a scheme. */
export function droppedURL(uriList: string, plain: string): string | null {
  const lines = [...uriList.split(/\r?\n/), plain].map((line) => line.trim());
  const url = lines.find((line) => line && !line.startsWith("#") && /^[a-z][a-z0-9+.-]*:/i.test(line));
  return url ?? null;
}

/** The title of a dropped link: a dragged link's text (`text/html`'s anchor), else none. The
 * native bar read `public.url-name`, which a page never sees; a link drag also writes its HTML. */
export function droppedTitle(html: string, url: string): string {
  const match = /<a\b[^>]*>([\s\S]*?)<\/a>/i.exec(html);
  if (!match) return "";
  const text = (match[1] ?? "")
    .replace(/<[^>]*>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
  return text === url ? "" : text;
}

/** Where a click opens (`BookmarkOpenDisposition.from`): Cmd or the middle button a background
 * tab, with Shift a new tab; Shift alone a new tab; else the current tab. */
export function disposition(modifiers: { metaKey: boolean; shiftKey: boolean }, middle = false): Disposition {
  if (modifiers.metaKey || middle) return modifiers.shiftKey ? "newTab" : "backgroundTab";
  if (modifiers.shiftKey) return "newTab";
  return "current";
}

/** One row of a folder's native menu (`cmux.bookmarksBar.menu`). The host draws it as an NSMenu
 * item and fills a submenu only when it opens. A `partial` folder's `children` are only those the
 * read reached (it was cut short): the host asks the page for its rows (`folderRows`) when it opens. */
export type MenuRow =
  | { kind: "bookmark"; id: string; title: string; url: string; favicon_key?: string | null }
  | { kind: "folder"; id: string; title: string; icon?: string | null; children: MenuRow[]; partial?: true }
  | { kind: "openAll"; folder: string; title: string }
  | { kind: "empty"; title: string }
  | { kind: "separator" };

export interface MenuWords {
  empty: string;
  openAll: (count: number) => string;
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Long titles are cut in the middle of a menu, not at the screen edge (60 characters as Swift
 * counts them: grapheme clusters). */
export function menuTitle(title: string): string {
  const chars = Array.from(graphemes.segment(title), (part) => part.segment);
  return chars.length > 60 ? `${chars.slice(0, 57).join("")}…` : title;
}

/** The children of each parent in a `bookmarks.children` subtree, in order. */
export function groupChildren(rows: readonly Bookmark[]): Map<string, Bookmark[]> {
  const groups = new Map<string, Bookmark[]>();
  for (const row of rows) {
    const siblings = groups.get(row.parent);
    if (siblings) siblings.push(row);
    else groups.set(row.parent, [row]);
  }
  for (const siblings of groups.values()) siblings.sort((a, b) => a.index - b.index);
  return groups;
}

/**
 * The rows of a folder's menu, the native BookmarkFolderMenu's: `leading` first (the overflow's
 * hidden bar items), then the folder's children; "(empty)" when there is nothing, else "Open All"
 * after a separator when the folder holds more than one link. Subfolders nest the same way. With
 * `complete`, a subfolder not in it is `partial`: its rows are those of `groups` alone, with no
 * "(empty)" and no "Open All" (the host reads the rest when it opens).
 */
export function menuRows(
  groups: ReadonlyMap<string, readonly Bookmark[]>,
  folder: string | null,
  words: MenuWords,
  leading: readonly Bookmark[] = [],
  complete?: ReadonlySet<string>,
): MenuRow[] {
  const own = folder ? (groups.get(folder) ?? []) : [];
  const nodes = [...leading, ...own];
  const rows = nodes.map((node) => row(groups, node, words, complete));
  if (rows.length === 0) return [{ kind: "empty", title: words.empty }];
  const links = own.filter((node) => node.kind !== "folder").length;
  if (folder && links > 1) rows.push({ kind: "separator" }, { kind: "openAll", folder, title: words.openAll(links) });
  return rows;
}

function row(
  groups: ReadonlyMap<string, readonly Bookmark[]>,
  node: Bookmark,
  words: MenuWords,
  complete?: ReadonlySet<string>,
): MenuRow {
  const title = menuTitle(displayTitle(node));
  if (node.kind === "folder") {
    const folder = { kind: "folder", id: node.id, title, icon: node.icon ?? null } as const;
    if (complete && !complete.has(node.id)) {
      const known = (groups.get(node.id) ?? []).map((child) => row(groups, child, words, complete));
      return { ...folder, children: known, partial: true };
    }
    return { ...folder, children: menuRows(groups, node.id, words, [], complete) };
  }
  return { kind: "bookmark", id: node.id, title, url: node.url ?? "", favicon_key: node.favicon_key ?? null };
}

/**
 * The folders of a depth-first `bookmarks.children` read whose contents it holds whole: all of
 * them, unless the read was cut short, when the last row's folder and its ancestors may not be.
 */
export function completeFolders(rows: readonly Bookmark[], truncated: boolean): Set<string> {
  const complete = new Set(rows.filter((node) => node.kind === "folder").map((node) => node.id));
  const last = rows[rows.length - 1];
  if (!truncated || !last) return complete;
  const parents = new Map(rows.map((node) => [node.id, node.parent]));
  for (let id: string | undefined = last.id; id !== undefined; id = parents.get(id)) complete.delete(id);
  return complete;
}
