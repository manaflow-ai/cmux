// Pure helpers of the Passwords page: search, sort and grouping by site. No state, no I/O.
import type { PasswordException, SavedPasskey, SavedPassword } from "./types";

export type SortMode = "site" | "recent" | "mostUsed";

export interface SiteGroup {
  site: string;
  rows: SavedPassword[];
}

/** Lowercased tokens of a query; every token must match. */
export function tokens(text: string): string[] {
  return text.toLowerCase().split(/\s+/).filter(Boolean);
}

function matches(fields: string[], query: string[]): boolean {
  if (query.length === 0) return true;
  const haystack = fields.join(" ").toLowerCase();
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
