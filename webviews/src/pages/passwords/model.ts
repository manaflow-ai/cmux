// Pure helpers of the Passwords page: search, sort and grouping by site. No state, no I/O.
import { foldFind } from "../../find/fold";
import type { PasswordException, SavedPasskey, SavedPassword } from "./types";

export type SortMode = "site" | "recent" | "mostUsed";

export interface SiteGroup {
  site: string;
  rows: SavedPassword[];
}

/**
 * The shared find fold, and a decomposed `I` + U+0307 (the letters `İ` lowercases to) folds to `i`
 * too: a query typed either way matches both. This page has no match offsets, so the shorter
 * string is safe.
 */
function fold(text: string): string {
  return foldFind(text).replace(/i\u0307/g, "i");
}

/** Folded tokens of a query; every token must match. */
export function tokens(text: string): string[] {
  return fold(text).split(/\s+/).filter(Boolean);
}

function matches(fields: string[], query: string[]): boolean {
  if (query.length === 0) return true;
  const haystack = fold(fields.join(" "));
  return query.every((token) => haystack.includes(token));
}

export function filterPasswords(rows: SavedPassword[], text: string): SavedPassword[] {
  const query = tokens(text);
  return rows.filter((row) => matches([row.site, row.username, row.url], query));
}

export function filterPasskeys(rows: SavedPasskey[], text: string): SavedPasskey[] {
  const query = tokens(text);
  return rows.filter((row) => matches([row.rp_id, row.user_name, row.user_display_name], query));
}

export function filterExceptions(rows: PasswordException[], text: string): PasswordException[] {
  const query = tokens(text);
  return rows.filter((row) => matches([row.site], query));
}

const bySite = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base" });

/**
 * Sign-ins grouped by site. `site` orders groups by name and rows by username; `recent` and
 * `mostUsed` order groups by their best row, so the site used last (or most) comes first.
 */
export function groupBySite(rows: SavedPassword[], sort: SortMode): SiteGroup[] {
  const groups = new Map<string, SavedPassword[]>();
  for (const row of rows) {
    const list = groups.get(row.site);
    if (list) list.push(row);
    else groups.set(row.site, [row]);
  }
  const score = (row: SavedPassword) => (sort === "recent" ? (row.last_used ?? -1) : row.times_used);
  const out = [...groups].map(([site, list]) => ({
    site,
    rows:
      sort === "site"
        ? [...list].sort((a, b) => bySite(a.username, b.username) || a.id.localeCompare(b.id))
        : [...list].sort((a, b) => score(b) - score(a) || bySite(a.username, b.username)),
  }));
  const best = (group: SiteGroup) => (group.rows[0] ? score(group.rows[0]) : -1);
  if (sort === "site") return [...out].sort((a, b) => bySite(a.site, b.site));
  return [...out].sort((a, b) => best(b) - best(a) || bySite(a.site, b.site));
}

export function sortPasskeys(rows: SavedPasskey[]): SavedPasskey[] {
  return [...rows].sort((a, b) => bySite(a.rp_id, b.rp_id) || bySite(a.user_name, b.user_name));
}

export function sortExceptions(rows: PasswordException[]): PasswordException[] {
  return [...rows].sort((a, b) => bySite(a.site, b.site));
}

/** The first letter of a site for its badge ("github.com" -> "G"). */
export function siteInitial(site: string): string {
  const name = site.replace(/^www\./, "");
  return (name.match(/[\p{L}\p{N}]/u)?.[0] ?? "?").toUpperCase();
}

/**
 * The reply's rows, each one that did not change kept as the object the page already holds: a reply
 * re-sends every list, and a memoized row draws again only for the row that changed.
 */
export function keepUnchanged<T extends { id: string }>(previous: readonly T[], next: readonly T[]): T[] {
  if (!previous.length) return [...next];
  const held = new Map(previous.map((row) => [row.id, row]));
  return next.map((row) => {
    const old = held.get(row.id);
    return old && sameRow(old, row) ? old : row;
  });
}

function sameRow<T extends object>(a: T, b: T): boolean {
  const keys = Object.keys(a) as (keyof T)[];
  return keys.length === Object.keys(b).length && keys.every((key) => a[key] === b[key]);
}

/** One windowed item of the saved logins: a site's header, or one of its logins. */
export type LoginItem =
  | { kind: "site"; site: string }
  | { kind: "login"; site: string; row: SavedPassword; last: boolean; position: number };

/** A windowed section's items, and an item's key to its index (a kept row is found without a scan). */
export interface Windowed<T> {
  items: T[];
  keys: string[];
  place: Map<string, number>;
  /** The rows among the items: the screen reader's "3 of 1000". */
  rows: number;
}

function windowed<T>(items: T[], key: (item: T) => string, rows: number): Windowed<T> {
  const keys = items.map(key);
  return { items, keys, place: new Map(keys.map((item, index) => [item, index])), rows };
}

/** Built once per reply, search or sort, not per render, scroll or focus. */
export function loginList(groups: readonly SiteGroup[]): Windowed<LoginItem> {
  const items: LoginItem[] = [];
  let position = 0;
  for (const group of groups) {
    items.push({ kind: "site", site: group.site });
    group.rows.forEach((row, index) =>
      items.push({ kind: "login", site: group.site, row, last: index === group.rows.length - 1, position: ++position }),
    );
  }
  return windowed(items, (item) => (item.kind === "site" ? `site:${item.site}` : `login:${item.row.id}`), position);
}

export function rowList<T extends { id: string }>(rows: T[], prefix: string): Windowed<T> {
  return windowed(rows, (row) => `${prefix}:${row.id}`, rows.length);
}
