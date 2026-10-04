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
    .filter((entry) => entry.kind === "dir" || mode === "anyFile" || (mode === "file" && isMarkdownName(entry.name)))
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
    if (mode !== "folder") set.add(parentPath(path) ?? path);
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

// The key table lives with the drill-down widget (ui/drillKeys.ts); the palette picker reads it here.
export {
  drillKeyAction as pickerKeyAction,
  type DrillAction as PickerAction,
  type DrillKey as PickerKey,
} from "../ui/drillKeys";

/** A typed query that jumps: `name/` enters that folder of the level. */
export function queryJump(query: string, rows: readonly PickerRow[]): { path: string } | null {
  if (query.length > 1 && query.endsWith("/") && !isPathQuery(query)) {
    const name = query.slice(0, -1).toLowerCase();
    const row = rows.find((candidate) => candidate.kind === "dir" && candidate.name.toLowerCase() === name);
    if (row) return { path: row.path };
  }
  return null;
}

/** Whether a query is a path: it starts with `/` or `~/` (path mode). */
export function isPathQuery(query: string): boolean {
  return query.startsWith("/") || query.startsWith("~/");
}

/**
 * A path query split into the folder to list and the text that filters it: `~/fun/cm` lists
 * `<home>/fun` filtered by `cm`; `/` lists the root. `~` before any listing named home is `"~"`,
 * which the host resolves (`cmux.picker.list {path: "~"}`). Null when the query is not a path.
 */
export function pathQuery(query: string, home: string | null): { dir: string; rest: string } | null {
  if (!isPathQuery(query)) return null;
  const cut = query.lastIndexOf("/");
  const head = query.slice(0, cut);
  const rest = query.slice(cut + 1);
  const base = home?.replace(/\/+$/, "") ?? "~";
  const dir = head.startsWith("~") ? `${base}${head.slice(1)}` : head;
  return { dir: dir === "" ? "/" : dir.replace(/\/+$/, "") || "/", rest };
}

/** The path query that shows folder `path` (home written as `~`), ending in `/`. */
export function folderQuery(path: string, home: string | null): string {
  const base = home?.replace(/\/+$/, "") ?? null;
  if (base && (path === base || path.startsWith(`${base}/`))) return `~${path.slice(base.length)}/`;
  return path === "/" ? "/" : `${path}/`;
}

export interface PickerLocation {
  name: string;
  path: string;
  kind: "dir";
  location: true;
}

/**
 * The Locations section (shown above the level while the query is empty): home, the computer's
 * root, then up to `limit` recent folders (in the file modes, the folders of recent files). The shown
 * folder itself is left out.
 */
export function pickerLocations(options: {
  home: string | null;
  current: string | null;
  recents: readonly string[];
  mode: PickerMode;
  labels: { home: string; computer: string };
  limit?: number;
}): PickerLocation[] {
  const { home, current, recents, mode, labels, limit = 3 } = options;
  const seen = new Set<string>();
  const out: PickerLocation[] = [];
  const add = (path: string | null, name: string) => {
    if (!path || seen.has(path) || path === current) return;
    seen.add(path);
    out.push({ name, path, kind: "dir", location: true });
  };
  if (home) add(home.replace(/\/+$/, ""), labels.home);
  add("/", labels.computer);
  let added = 0;
  for (const recent of recents) {
    if (added >= limit) break;
    const folder = mode === "folder" ? recent : parentPath(recent);
    if (!folder || seen.has(folder) || folder === current) continue;
    add(folder, folder.split("/").filter(Boolean).pop() ?? folder);
    added += 1;
  }
  return out;
}
