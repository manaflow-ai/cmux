// Pure rules of the Bookmarks page, the Swift manager's (CmuxNextBookmarks BookmarkManagerModel,
// BookmarkURL, BookmarkFolderChoice): the tree over a listing, folder paths and choices, the typed
// URL, the drop rules, and the ops one editor save or one drop makes. No I/O.
import { ROOTS, type Bookmark, type BookmarkOp } from "./types";

export interface Tree {
  nodes: ReadonlyMap<string, Bookmark>;
  /** Each parent's children in index order (roots and folders). */
  children: ReadonlyMap<string, readonly Bookmark[]>;
}

export interface RootTitles {
  bar: string;
  other: string;
}

const NONE: readonly Bookmark[] = [];

/** The tree of a `cmux.bookmarks.list` listing. */
export function buildTree(listing: readonly Bookmark[]): Tree {
  const nodes = new Map<string, Bookmark>();
  const children = new Map<string, Bookmark[]>();
  for (const node of listing) {
    nodes.set(node.id, node);
    const siblings = children.get(node.parent);
    if (siblings) siblings.push(node);
    else children.set(node.parent, [node]);
  }
  for (const siblings of children.values()) siblings.sort((a, b) => a.index - b.index);
  return { nodes, children };
}

export function childrenOf(tree: Tree, parent: string): readonly Bookmark[] {
  return tree.children.get(parent) ?? NONE;
}

export function isRoot(id: string): boolean {
  return (ROOTS as readonly string[]).includes(id);
}

/** True when `id` is `ancestor` itself or anywhere under it. */
export function isWithin(tree: Tree, id: string, ancestor: string): boolean {
  for (let current: string | undefined = id; current !== undefined; current = tree.nodes.get(current)?.parent) {
    if (current === ancestor) return true;
  }
  return false;
}

/** A row's title: its own, else its URL as a list shows it. */
export function displayTitle(node: Bookmark): string {
  if (node.title) return node.title;
  return node.url ? displayURL(node.url) : "";
}

/** `github.com/foo` for `https://github.com/foo`; other schemes stay whole. */
export function displayURL(url: string): string {
  const match = /^https?:\/\//i.exec(url);
  if (!match) return url;
  let text = url.slice(match[0].length);
  if (text.toLowerCase().startsWith("www.")) text = text.slice(4);
  if (text.endsWith("/") && text.indexOf("/") === text.length - 1) text = text.slice(0, -1);
  return text;
}

/** A folder's title, a root's included. */
export function folderTitle(tree: Tree, id: string, titles: RootTitles): string {
  if (id === "bar") return titles.bar;
  if (id === "other") return titles.other;
  const node = tree.nodes.get(id);
  return node ? displayTitle(node) : "";
}

/** The titles from the root to `id`'s parent ("Bookmarks Bar › Work" for a node in Work). */
export function folderPath(tree: Tree, id: string, titles: RootTitles): string[] {
  const path: string[] = [];
  let current = tree.nodes.get(id)?.parent;
  for (let folder = current === undefined ? undefined : tree.nodes.get(current); folder;) {
    path.unshift(displayTitle(folder));
    current = folder.parent;
    folder = tree.nodes.get(current);
  }
  if (current === "bar" || current === "other") path.unshift(folderTitle(tree, current, titles));
  return path;
}

export const PATH_SEPARATOR = " › ";

/** The folders from the root down to `folder` itself, for the breadcrumb. */
export function folderTrail(tree: Tree, folder: string, titles: RootTitles): Array<{ id: string; title: string }> {
  const trail: Array<{ id: string; title: string }> = [];
  for (let current: string | undefined = folder; current !== undefined;) {
    trail.unshift({ id: current, title: folderTitle(tree, current, titles) });
    if (isRoot(current)) break;
    current = tree.nodes.get(current)?.parent;
  }
  return trail;
}

export interface FolderChoice {
  id: string;
  title: string;
  depth: number;
}

/** Every folder in tree order under its root, without `exclude` and what is under it (a folder
 * cannot move into itself). The editor's folder picker and the left tree both read this. */
export function folderChoices(tree: Tree, titles: RootTitles, exclude?: string): FolderChoice[] {
  const result: FolderChoice[] = [];
  const visit = (parent: string, depth: number) => {
    for (const node of childrenOf(tree, parent)) {
      if (node.kind !== "folder" || node.id === exclude) continue;
      result.push({ id: node.id, title: displayTitle(node), depth });
      visit(node.id, depth + 1);
    }
  };
  for (const root of ROOTS) {
    result.push({ id: root, title: folderTitle(tree, root, titles), depth: 0 });
    visit(root, 1);
  }
  return result;
}

/** The left tree's rows: `folderChoices` with a collapsed folder's descendants left out. */
export function treeRows(tree: Tree, titles: RootTitles, collapsed: ReadonlySet<string>): FolderChoice[] {
  const rows: FolderChoice[] = [];
  let hiddenBelow = Infinity;
  for (const choice of folderChoices(tree, titles)) {
    if (choice.depth > hiddenBelow) continue;
    hiddenBelow = collapsed.has(choice.id) ? choice.depth : Infinity;
    rows.push(choice);
  }
  return rows;
}

export function hasSubfolders(tree: Tree, id: string): boolean {
  return childrenOf(tree, id).some((node) => node.kind === "folder");
}

/** How many URL bookmarks sit directly in `folder` (Open All (n)). */
export function urlCount(tree: Tree, folder: string): number {
  return childrenOf(tree, folder).filter((node) => node.kind === "url").length;
}

/** A URL typed in the editor, else null. Text without a scheme gets `https://`; `localhost:3000`
 * is a host and port, not a scheme, and gets `http://`. */
export function parseTypedURL(text: string): string | null {
  const trimmed = text.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;
  const colon = trimmed.indexOf(":");
  if (colon > 0) {
    const scheme = trimmed.slice(0, colon);
    const rest = trimmed.slice(colon + 1);
    const isPort = /^\d/.test(rest) && !rest.startsWith("//");
    if (!isPort && /^[a-z][a-z0-9+.-]*$/i.test(scheme) && absolute(trimmed)) return trimmed;
    if (isPort) return absolute(`http://${trimmed}`) ? `http://${trimmed}` : null;
  }
  if (!trimmed.includes(".") && !trimmed.toLowerCase().startsWith("localhost")) return null;
  return absolute(`https://${trimmed}`) ? `https://${trimmed}` : null;
}

function absolute(text: string): boolean {
  try {
    return new URL(text).protocol.length > 1;
  } catch {
    return false;
  }
}

/** Where a drop puts the dragged nodes: a parent and the final index of the first of them. */
export interface DropPlace {
  parent: string;
  index: number;
}

/** The dragged ids that are not under another dragged id, in tree order. A folder carries its
 * contents, so deleting or moving its descendants too would act on them twice. */
export function topmost(tree: Tree, ids: Iterable<string>): string[] {
  const chosen = new Set([...ids].filter((id) => tree.nodes.has(id)));
  const roots = [...chosen].filter((id) => {
    for (let up = tree.nodes.get(id)?.parent; up !== undefined; up = tree.nodes.get(up)?.parent) {
      if (chosen.has(up)) return false;
    }
    return true;
  });
  return sortInTreeOrder(tree, roots);
}

function sortInTreeOrder(tree: Tree, ids: string[]): string[] {
  const order = new Map<string, number>();
  let next = 0;
  const visit = (parent: string) => {
    for (const node of childrenOf(tree, parent)) {
      order.set(node.id, next++);
      if (node.kind === "folder") visit(node.id);
    }
  };
  for (const root of ROOTS) visit(root);
  return [...ids].sort((a, b) => (order.get(a) ?? 0) - (order.get(b) ?? 0));
}

/** The drop of `dragged` into `folder` (a list row's folder, or a tree row): at its end. Null for
 * a drop into a dragged node or anything under one. */
export function dropInto(tree: Tree, dragged: readonly string[], folder: string): DropPlace | null {
  if (dragged.length === 0 || dragged.some((id) => isWithin(tree, folder, id))) return null;
  const moving = new Set(dragged);
  return { parent: folder, index: childrenOf(tree, folder).filter((node) => !moving.has(node.id)).length };
}

/** A drop on a row: into it when it is a folder (and not a dragged one or under one), else just
 * before it among its siblings. Null when it lands on itself or under a dragged node. */
export function dropOnRow(tree: Tree, dragged: readonly string[], target: Bookmark): DropPlace | null {
  if (dragged.length === 0 || dragged.includes(target.id)) return null;
  if (target.kind === "folder") {
    const into = dropInto(tree, dragged, target.id);
    if (into) return into;
  }
  if (dragged.some((id) => isWithin(tree, target.parent, id))) return null;
  const moving = new Set(dragged);
  const siblings = childrenOf(tree, target.parent).filter((node) => !moving.has(node.id));
  return { parent: target.parent, index: siblings.findIndex((node) => node.id === target.id) };
}

/** The move ops that put `dragged` (topmost, in tree order) at `place` as one block, each `index`
 * the node's final position among the destination's children when its op runs. */
export function moveOps(tree: Tree, dragged: readonly string[], place: DropPlace): BookmarkOp[] {
  const moving = topmost(tree, dragged);
  const others = childrenOf(tree, place.parent)
    .map((node) => node.id)
    .filter((id) => !moving.includes(id));
  // The block goes before this node (or at the end); each op runs against the order before it.
  const anchor = others[place.index];
  let current = childrenOf(tree, place.parent).map((node) => node.id);
  const ops: BookmarkOp[] = [];
  let previous: string | undefined;
  for (const id of moving) {
    const rest = current.filter((other) => other !== id);
    const index =
      previous !== undefined ? rest.indexOf(previous) + 1 : anchor !== undefined ? rest.indexOf(anchor) : rest.length;
    const node = tree.nodes.get(id);
    if (!(node?.parent === place.parent && current.indexOf(id) === index)) {
      ops.push({ op: "move", bookmark: id, parent: place.parent, index });
    }
    current = [...rest.slice(0, index), id, ...rest.slice(index)];
    previous = id;
  }
  return ops;
}

/** The delete ops of a selection: each topmost node once (a folder takes its contents). */
export function deleteOps(tree: Tree, ids: Iterable<string>): BookmarkOp[] {
  return topmost(tree, ids).map((bookmark) => ({ op: "delete", bookmark }));
}

export type EditorMode =
  | { kind: "addBookmark" }
  | { kind: "addFolder" }
  /** Edit a URL bookmark, or Rename a folder. */
  | { kind: "edit"; id: string };

export interface EditorState {
  mode: EditorMode;
  isFolder: boolean;
  title: string;
  url: string;
  folder: string;
}

export type EditorResult = { ok: true; ops: BookmarkOp[] } | { ok: false; reason: "invalidURL" };

/** The ops of one editor save (Return or Save), or why the editor stays open. */
export function editorOps(tree: Tree, profile: string, state: EditorState): EditorResult {
  const url = state.isFolder ? null : parseTypedURL(state.url);
  if (!state.isFolder && url === null) return { ok: false, reason: "invalidURL" };
  const create = (kind: "url" | "folder"): BookmarkOp => ({
    op: "create",
    id: null,
    browser_profile_id: profile,
    parent: state.folder,
    index: null,
    kind,
    title: state.title,
    ...(kind === "url" && url ? { url } : {}),
    favicon_key: null,
    source_key: null,
    created_ms: null,
  });
  const mode = state.mode;
  if (mode.kind === "addBookmark") return { ok: true, ops: [create("url")] };
  if (mode.kind === "addFolder") return { ok: true, ops: [create("folder")] };
  const node = tree.nodes.get(mode.id);
  if (!node) return { ok: true, ops: [] };
  const ops: BookmarkOp[] = [];
  const title = state.title === node.title ? undefined : state.title;
  const newURL = url === null || url === (node.url ?? null) ? undefined : url;
  if (title !== undefined || newURL !== undefined) {
    ops.push({
      op: "update",
      bookmark: node.id,
      ...(title !== undefined ? { title } : {}),
      ...(newURL !== undefined ? { url: newURL } : {}),
    });
  }
  if (state.folder !== node.parent) {
    const place = dropInto(tree, [node.id], state.folder);
    if (place) ops.push({ op: "move", bookmark: node.id, parent: place.parent, index: place.index });
  }
  return { ok: true, ops };
}

/** The editor for a node: Edit for a bookmark, Rename for a folder. */
export function editState(node: Bookmark): EditorState {
  return {
    mode: { kind: "edit", id: node.id },
    isFolder: node.kind === "folder",
    title: node.title,
    url: node.url ?? "",
    folder: node.parent,
  };
}

/** The next selected id after Up (-1) or Down (+1) over `rows`; the first row when none is. */
export function moveSelection(rows: readonly Bookmark[], focus: string | undefined, delta: 1 | -1): string | undefined {
  if (rows.length === 0) return undefined;
  const at = focus === undefined ? -1 : rows.findIndex((row) => row.id === focus);
  if (at < 0) return rows[delta > 0 ? 0 : rows.length - 1]?.id;
  return rows[Math.min(rows.length - 1, Math.max(0, at + delta))]?.id;
}

/** Shift-click: every row from the anchor to `id`, in list order. */
export function rangeSelection(rows: readonly Bookmark[], anchor: string | undefined, id: string): string[] {
  const to = rows.findIndex((row) => row.id === id);
  const from = anchor === undefined ? -1 : rows.findIndex((row) => row.id === anchor);
  if (to < 0) return [];
  if (from < 0) return [id];
  const [start, end] = from <= to ? [from, to] : [to, from];
  return rows.slice(start, end + 1).map((row) => row.id);
}

/** The cache key of a row's icon: a new favicon or folder icon asks again. */
export function iconKey(node: Bookmark): string {
  return `${node.id}\u0000${node.favicon_key ?? ""}\u0000${node.icon ?? ""}`;
}

/** The bookmark id of the `#/?reveal=<id>` route a page opened to show one bookmark starts at. */
export function revealRoute(hash: string): string | null {
  const query = hash.replace(/^#\/?/, "").replace(/^\?/, "");
  return new URLSearchParams(query).get("reveal") || null;
}
