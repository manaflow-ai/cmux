// Settings > Menus: the edits the page makes to a right-click menu's arrangement (Swift
// `ContextMenuLayout`): the whole menu as a tree, so any row goes anywhere at any depth. A node is a
// row key, `-` for a separator, or a submenu `{key, title?, items}`: the app's (`folder:<name>`) or
// the person's (`group:<id>`, with a title). The app sends the tree normalized (every row once,
// hidden rows kept in place), so these edits keep that shape and the page saves the whole tree.
import type { ContextMenuState, MenuLayout, MenuNode } from "./ops";

export const SEPARATOR = "-";
export const MORE = "folder:more";
export const GROUP_PREFIX = "group:";

/** A node's place: its index in each container from the top level down. */
export type Path = number[];

export type Folder = Extract<MenuNode, object>;

export const isFolder = (node: MenuNode): node is Folder => typeof node === "object";
export const keyOf = (node: MenuNode): string => (isFolder(node) ? node.key : node);
export const isGroup = (key: string) => key.startsWith(GROUP_PREFIX);

/** One row the editor draws: the node, where it is, how deep, and whether the menu hides it. */
export type VisibleRow = { node: MenuNode; path: Path; depth: number; hidden: boolean; parentHidden: boolean };

/** The rows the editor shows, top to bottom: every node, and the rows of each open submenu. */
export function visibleRows(layout: MenuLayout, open: ReadonlySet<string>): VisibleRow[] {
  const hidden = new Set(layout.hidden);
  const rows: VisibleRow[] = [];
  const walk = (nodes: MenuNode[], prefix: Path, parentHidden: boolean) => {
    nodes.forEach((node, index) => {
      const path = [...prefix, index];
      const isHidden = hidden.has(keyOf(node));
      rows.push({ node, path, depth: prefix.length, hidden: isHidden, parentHidden });
      if (isFolder(node) && open.has(node.key)) walk(node.items, path, parentHidden || isHidden);
    });
  };
  walk(layout.items, [], false);
  return rows;
}

/** The node at `path`, or undefined. */
export function nodeAt(items: MenuNode[], path: Path): MenuNode | undefined {
  let nodes = items;
  let node: MenuNode | undefined;
  for (const index of path) {
    node = nodes[index];
    if (node === undefined) return undefined;
    nodes = isFolder(node) ? node.items : [];
  }
  return node;
}

/** A deep copy of `items`, so an edit never changes the tree React drew. */
function copy(items: MenuNode[]): MenuNode[] {
  return items.map((node) => (isFolder(node) ? { ...node, items: copy(node.items) } : node));
}

/** The container (a node list) at `parent` in `items`: the top level for `[]`. */
function container(items: MenuNode[], parent: Path): MenuNode[] | undefined {
  if (parent.length === 0) return items;
  const node = nodeAt(items, parent);
  return node && isFolder(node) ? node.items : undefined;
}

export const samePath = (a: Path, b: Path) => a.length === b.length && a.every((value, index) => value === b[index]);
/** Whether `path` is `ancestor` or inside it. */
export const within = (path: Path, ancestor: Path) =>
  ancestor.length <= path.length && ancestor.every((value, index) => path[index] === value);

/**
 * Moves the node at `from` to index `index` of the container at `parent`, as counted before the
 * move (the node's old place still counts). A submenu never goes into itself.
 */
export function move(layout: MenuLayout, from: Path, parent: Path, index: number): MenuLayout {
  if (within(parent, from)) return layout;
  const items = copy(layout.items);
  const source = container(items, from.slice(0, -1));
  const target = container(items, parent);
  const at = from[from.length - 1]!;
  if (!source || !target || source[at] === undefined) return layout;
  // Mark the drop place, take the node out, then put it at the mark: indices stay as they were.
  const mark: Folder = { key: "\u0000drop", items: [] };
  target.splice(Math.max(0, Math.min(index, target.length)), 0, mark);
  const [node] = source.splice(source === target && target.indexOf(mark) <= at ? at + 1 : at, 1);
  target.splice(target.indexOf(mark), 1, node!);
  return { ...layout, items };
}

/** Moves the node at `path` one place up or down inside its submenu. */
export function step(layout: MenuLayout, path: Path, by: -1 | 1): MenuLayout {
  const parent = path.slice(0, -1);
  const at = path[path.length - 1]!;
  const siblings = container(layout.items, parent);
  if (!siblings || at + by < 0 || at + by >= siblings.length) return layout;
  return move(layout, path, parent, by > 0 ? at + 2 : at - 1);
}

/** Moves the node at `path` to the end of the submenu at `parent` (`[]`: the top level). */
export function moveInto(layout: MenuLayout, path: Path, parent: Path): MenuLayout {
  const target = container(layout.items, parent);
  return target ? move(layout, path, parent, target.length) : layout;
}

/** Hides or shows `key` where it is (a hidden submenu hides what it holds). */
export function toggleHidden(layout: MenuLayout, key: string): MenuLayout {
  return layout.hidden.includes(key)
    ? { ...layout, hidden: layout.hidden.filter((item) => item !== key) }
    : { ...layout, hidden: [...layout.hidden, key] };
}

/** Adds a separator at the end of the top level. */
export function addSeparator(layout: MenuLayout): MenuLayout {
  return { ...layout, items: [...copy(layout.items), SEPARATOR] };
}

/** Takes out the node at `path` when it is a separator. */
export function removeSeparator(layout: MenuLayout, path: Path): MenuLayout {
  if (nodeAt(layout.items, path) !== SEPARATOR) return layout;
  const items = copy(layout.items);
  container(items, path.slice(0, -1))!.splice(path[path.length - 1]!, 1);
  return { ...layout, items };
}

/** A new submenu of the person's, `title`, at the end of the top level, and its key. */
export function addGroup(layout: MenuLayout, title: string, id: string): { layout: MenuLayout; key: string } {
  const key = `${GROUP_PREFIX}${id}`;
  return { layout: { ...layout, items: [...copy(layout.items), { key, title, items: [] }] }, key };
}

/** Renames the person's submenu at `path`. */
export function renameGroup(layout: MenuLayout, path: Path, title: string): MenuLayout {
  const items = copy(layout.items);
  const node = nodeAt(items, path);
  if (!node || !isFolder(node) || !isGroup(node.key)) return layout;
  node.title = title;
  return { ...layout, items };
}

/** Deletes the person's submenu at `path`; what it held takes its place. */
export function deleteGroup(layout: MenuLayout, path: Path): MenuLayout {
  const items = copy(layout.items);
  const node = nodeAt(items, path);
  if (!node || !isFolder(node) || !isGroup(node.key)) return layout;
  container(items, path.slice(0, -1))!.splice(path[path.length - 1]!, 1, ...node.items);
  return { ...layout, hidden: layout.hidden.filter((key) => key !== node.key), items };
}

/** A submenu a node can move into: its path and the titles that lead to it. */
export type Destination = { path: Path; trail: string[] };

/**
 * Every submenu the node at `path` can move into, in menu order, the top level first; a submenu
 * never into itself or one inside it.
 */
export function destinations(layout: MenuLayout, path: Path, title: (node: Folder) => string): Destination[] {
  const result: Destination[] = [{ path: [], trail: [] }];
  const walk = (nodes: MenuNode[], prefix: Path, trail: string[]) => {
    nodes.forEach((node, index) => {
      const at = [...prefix, index];
      if (!isFolder(node) || within(at, path)) return;
      const names = [...trail, title(node)];
      result.push({ path: at, trail: names });
      walk(node.items, at, names);
    });
  };
  walk(layout.items, [], []);
  return result;
}

const equal = (a: MenuNode[], b: MenuNode[]): boolean =>
  a.length === b.length &&
  a.every((node, index) => {
    const other = b[index]!;
    if (!isFolder(node) || !isFolder(other)) return node === other;
    return node.key === other.key && (node.title ?? null) === (other.title ?? null) && equal(node.items, other.items);
  });

/** Whether two layouts arrange the menu the same way (the host re-sends equal layouts as new objects). */
export function sameLayout(a: MenuLayout, b: MenuLayout): boolean {
  return (
    equal(a.items, b.items) &&
    a.hidden.length === b.hidden.length &&
    a.hidden.every((key, index) => key === b.hidden[index])
  );
}

/** Whether `layout` is the app's own arrangement (Reset has nothing to do). */
export function isGenerated(menu: ContextMenuState, layout: MenuLayout): boolean {
  return layout.hidden.length === 0 && equal(layout.items, menu.generated.items);
}
