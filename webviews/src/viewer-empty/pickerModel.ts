// The pure model of the path picker (PathPicker.tsx): which rows a folder level shows, in which
// order, the breadcrumb, and what a key does. The app's palette folder and file picker follows the
// same rules (plans/cmux-next/diff-host.md, "Empty state"), so this file is its reference.
import { fuzzyFilter } from "./fuzzy";
import { isMarkdownName, type PickerEntry, type PickerMode } from "./ops";

export interface PickerRow extends PickerEntry {
  recent: boolean;
}

/** Rows to render at most; the rest are reached by typing. */
export const PICKER_ROW_LIMIT = 300;

/**
 * The rows of one level: folders (and markdown files in file mode), recent ones first, then
 * folders before files, then by name; then the fuzzy query filters and ranks them.
 */
export function pickerRows(
  entries: readonly PickerEntry[],
  query: string,
  mode: PickerMode,
  recent: ReadonlySet<string>,
): PickerRow[] {
  const rows = entries
    .filter((entry) => entry.kind === "dir" || (mode === "file" && isMarkdownName(entry.name)))
    .filter((entry) => query.startsWith(".") || !entry.name.startsWith("."))
    .map((entry) => ({ ...entry, recent: recent.has(entry.path) }));
  rows.sort(
    (a, b) =>
      Number(b.recent) - Number(a.recent) ||
      Number(b.kind === "dir") - Number(a.kind === "dir") ||
      a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }),
  );
  return fuzzyFilter(rows, query, (row) => row.name);
}

/** The recent paths a picker sorts first: each item, and for files also its folder. */
export function recentPathSet(paths: readonly string[], mode: PickerMode): Set<string> {
  const set = new Set<string>();
  for (const path of paths) {
    set.add(path);
    if (mode === "file") set.add(parentPath(path) ?? path);
  }
  return set;
}

/** The folder above `path`, or null at `/`. */
export function parentPath(path: string): string | null {
  if (path === "/" || path === "") return null;
  const trimmed = path.replace(/\/+$/, "");
  const index = trimmed.lastIndexOf("/");
  return index <= 0 ? "/" : trimmed.slice(0, index);
}

export interface Crumb {
  label: string;
  path: string;
}

/** The breadcrumb of `path`: `~` and the folders below home, or `/` and every folder. */
export function breadcrumb(path: string, home: string | null): Crumb[] {
  const base = home?.replace(/\/+$/, "") ?? null;
  if (base && (path === base || path.startsWith(`${base}/`))) {
    const crumbs: Crumb[] = [{ label: "~", path: base }];
    let current = base;
    for (const part of path.slice(base.length).split("/").filter(Boolean)) {
      current = `${current}/${part}`;
      crumbs.push({ label: part, path: current });
    }
    return crumbs;
  }
  const crumbs: Crumb[] = [{ label: "/", path: "/" }];
  let current = "";
  for (const part of path.split("/").filter(Boolean)) {
    current = `${current}/${part}`;
    crumbs.push({ label: part, path: current });
  }
  return crumbs;
}

export type PickerAction =
  | { kind: "move"; delta: number }
  | { kind: "edge"; to: "first" | "last" }
  | { kind: "enter" }
  | { kind: "up" }
  | { kind: "choose" }
  | { kind: "clear" }
  | { kind: "cancel" }
  | null;

export interface PickerKey {
  key: string;
  shiftKey?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
}

/**
 * What a key in the picker's field does. `caret` is the field's selection (start and end); Right
 * enters and Left goes up only from the end and the start of the text, so they still move the
 * caret inside a query.
 */
export function pickerKeyAction(
  event: PickerKey,
  state: { query: string; caretStart: number; caretEnd: number },
): PickerAction {
  const plain = !event.metaKey && !event.altKey;
  switch (event.key) {
    case "ArrowDown":
      return plain ? { kind: "move", delta: 1 } : null;
    case "ArrowUp":
      return plain ? { kind: "move", delta: -1 } : null;
    case "n":
      return event.ctrlKey && plain ? { kind: "move", delta: 1 } : null;
    case "p":
      return event.ctrlKey && plain ? { kind: "move", delta: -1 } : null;
    case "PageDown":
      return { kind: "move", delta: 10 };
    case "PageUp":
      return { kind: "move", delta: -10 };
    case "Home":
      return state.query === "" ? { kind: "edge", to: "first" } : null;
    case "End":
      return state.query === "" ? { kind: "edge", to: "last" } : null;
    case "Tab":
      return event.shiftKey || !plain || event.ctrlKey ? null : { kind: "enter" };
    case "ArrowRight":
      return plain && !event.shiftKey && state.caretStart === state.query.length && state.caretEnd === state.caretStart
        ? { kind: "enter" }
        : null;
    case "ArrowLeft":
      return plain && !event.shiftKey && state.caretStart === 0 && state.caretEnd === 0 ? { kind: "up" } : null;
    case "Backspace":
      return state.query === "" && plain ? { kind: "up" } : null;
    case "Enter":
      return plain ? { kind: "choose" } : null;
    case "Escape":
      return state.query === "" ? { kind: "cancel" } : { kind: "clear" };
    default:
      return null;
  }
}

/** A typed query that jumps: `~` home, `/` the root, `name/` into that folder of the level. */
export function queryJump(query: string, rows: readonly PickerRow[], home: string | null): { path: string } | null {
  // Before any listing named home, `~` asks the host for it (`cmux.picker.list {path: "~"}`).
  if (query === "~") return { path: home ?? "~" };
  if (query === "/") return { path: "/" };
  if (query.length > 1 && query.endsWith("/")) {
    const name = query.slice(0, -1).toLowerCase();
    const row = rows.find((candidate) => candidate.kind === "dir" && candidate.name.toLowerCase() === name);
    if (row) return { path: row.path };
  }
  return null;
}
