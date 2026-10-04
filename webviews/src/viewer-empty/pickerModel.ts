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

/** Whether a query is a path: it starts with `/` or `~/` (path mode). `~` alone is text. */
export function isPathQuery(query: string): boolean {
  return query.startsWith("/") || query.startsWith("~/");
}

export interface PathQuery {
  /** The folder part as typed, up to and with its last `/` (`~/fun/`). */
  typed: string;
  /** The folder to list (`~/` is home). */
  dir: string;
  /** The segment after the last `/`, being typed (`cm`). */
  rest: string;
}

/**
 * A path query split into the folder to list and the segment being typed: `~/fun/cm` lists
 * `<home>/fun` and completes `cm`; `/` lists the root. `~/` before any listing named home is
 * `"~"`, which the host resolves (`cmux.picker.list {path: "~"}`). Null when not a path.
 */
export function pathQuery(query: string, home: string | null): PathQuery | null {
  if (!isPathQuery(query)) return null;
  const cut = query.lastIndexOf("/");
  const typed = query.slice(0, cut + 1);
  const rest = query.slice(cut + 1);
  const base = home?.replace(/\/+$/, "") ?? "~";
  const head = typed.slice(0, -1);
  const dir = head.startsWith("~") ? `${base}${head.slice(1)}` : head;
  return { typed, dir: dir === "" ? "/" : dir.replace(/\/+$/, "") || "/", rest };
}

/**
 * The entries of a path query's folder that complete its segment: a case-insensitive prefix, in
 * the listing's order (folders first, Finder order); dot entries only for a segment starting `.`.
 */
export function pathCompletions(rows: readonly PickerRow[], rest: string): PickerRow[] {
  const wanted = rest.toLowerCase();
  return rows.filter(
    (row) => (rest.startsWith(".") || !row.name.startsWith(".")) && row.name.toLowerCase().startsWith(wanted),
  );
}

/** The query after completing `row` in path mode: a folder ends in `/`, so its entries follow. */
export function completedQuery(path: PathQuery, row: PickerEntry): string {
  return `${path.typed}${row.name}${row.kind === "dir" ? "/" : ""}`;
}

/** The path query that shows folder `path` (home written as `~`), ending in `/`. */
export function folderQuery(path: string, home: string | null): string {
  const base = home?.replace(/\/+$/, "") ?? null;
  if (base && (path === base || path.startsWith(`${base}/`))) return `~${path.slice(base.length)}/`;
  return path === "/" ? "/" : `${path}/`;
}

/** The kinds of place `cmux.picker.locations` answers, in its order (R89 Locations). */
export type PickerPlaceKind = "workspace" | "home" | "desktop" | "documents" | "downloads" | "iCloudDrive" | "pinned";

export interface PickerPlace {
  kind: PickerPlaceKind;
  path: string;
}

const PLACE_KINDS = new Set<string>([
  "workspace",
  "home",
  "desktop",
  "documents",
  "downloads",
  "iCloudDrive",
  "pinned",
]);

/**
 * The places of a `cmux.picker.locations` answer (`{locations: [{kind, path}]}`), in the host's
 * order, each folder once; malformed rows are dropped.
 */
export function parsePickerPlaces(value: unknown): PickerPlace[] {
  const rows = (value as { locations?: unknown } | null)?.locations;
  if (!Array.isArray(rows)) return [];
  const seen = new Set<string>();
  const out: PickerPlace[] = [];
  for (const row of rows as Array<Partial<PickerPlace> | null>) {
    if (!row || typeof row.path !== "string" || row.path === "" || !PLACE_KINDS.has(String(row.kind))) continue;
    const path = row.path.length > 1 ? row.path.replace(/\/+$/, "") : row.path;
    if (seen.has(path)) continue;
    seen.add(path);
    out.push({ kind: row.kind as PickerPlaceKind, path });
  }
  return out;
}

/** The standard places under `home` (the fallback when the host answers no locations). */
export function standardPlaces(home: string | null): PickerPlace[] {
  if (!home) return [];
  const base = home.replace(/\/+$/, "");
  return [
    { kind: "home", path: base },
    { kind: "desktop", path: `${base}/Desktop` },
    { kind: "documents", path: `${base}/Documents` },
    { kind: "downloads", path: `${base}/Downloads` },
  ];
}
