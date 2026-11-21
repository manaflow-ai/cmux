// Pure presentation model of the App Store page (plans/cmux-next/react-pages.md 3.3). Catalog
// semantics (tiers, install states, grants) belong to the app platform lead's owner; this file
// only filters, orders and labels what the owner returns.
import {
  APP_STORE_ID,
  HOME_ID,
  type AppIconRef,
  type AppTier,
  type CatalogApp,
  type GrantRow,
  type ScopeRisk,
} from "./types";

export const RiskLabel: Record<ScopeRisk, string> = {
  standard: "store.risk.standard",
  sensitive: "store.risk.sensitive",
  restricted: "store.risk.restricted",
};

export type StoreTab = "discover" | "installed";

/** `apps.store.layout` (Debug Settings): grid is the default; list and split are DEV variants. */
export type StoreLayout = "grid" | "list" | "split";

export function parseLayout(value: string | null | undefined): StoreLayout {
  return value === "list" || value === "split" ? value : "grid";
}

/**
 * How Discover draws a listing card (`card=` in the route, like `layout=`): `standard` is the
 * default; `compact` and `artwork` are DEV variants shown in the gallery (design/app-store.md).
 */
export type CardStyle = "standard" | "compact" | "artwork";

export function parseCardStyle(value: string | null | undefined): CardStyle {
  return value === "compact" || value === "artwork" ? value : "standard";
}

/** A listing's state on its card: not installed, installed and on, or installed and turned off. */
export type ItemState = "available" | "installed" | "off";

export function itemState(app: { installed: boolean; enabled?: boolean }): ItemState {
  if (!app.installed) return "available";
  return app.enabled === false ? "off" : "installed";
}

/** The page's route from its URL fragment: `#/discover?layout=list&app=<id>`, `#/installed`. */
export interface StoreRoute {
  tab: StoreTab;
  layout: StoreLayout;
  card: CardStyle;
  app?: string;
}

export function parseRoute(hash: string): StoreRoute {
  const text = hash.replace(/^#/, "");
  const [path, query = ""] = text.split("?", 2);
  const params = new URLSearchParams(query);
  const name = path.replace(/^\//, "");
  const tab: StoreTab = name === "installed" ? "installed" : "discover";
  return {
    tab,
    layout: parseLayout(params.get("layout")),
    card: parseCardStyle(params.get("card")),
    app: params.get("app") || undefined,
  };
}

/**
 * Every whitespace-separated word must appear in id, name, description, publisher, categories or
 * keywords (Swift `AppStoreListing.matches`), case insensitive.
 */
export function matches(app: CatalogApp, query: string): boolean {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const haystack = [app.id, app.name, app.description, app.publisher, ...app.categories, ...(app.keywords ?? [])]
    .join(" ")
    .toLowerCase();
  return words.every((word) => haystack.includes(word));
}

/**
 * Whether the page shows `app` at all: never the App Store itself or Home, which are places in
 * cmux, not apps to get (FIRST-PARTY-APPS; extensibility-DESIGN.md).
 */
export function listedInStore(app: { id: string }): boolean {
  return app.id !== APP_STORE_ID && app.id !== HOME_ID;
}

/**
 * Whether the page offers Remove for `app`. First-party apps are hidable, never removable
 * (FIRST-PARTY-APPS): the page offers Hide/Show instead, and the owner refuses an uninstall.
 */
export function isRemovable(app: { tier?: AppTier; hide_only?: boolean }): boolean {
  return app.hide_only === undefined ? app.tier !== "first-party" : !app.hide_only;
}

export function filterApps(apps: readonly CatalogApp[], query: string, category: string | undefined): CatalogApp[] {
  return apps.filter((app) => (!category || app.categories.includes(category)) && matches(app, query));
}

/**
 * The catalog's listings, each one that did not change kept as the object the page already holds:
 * every reload re-reads the whole catalog, and a memoized card draws again only for the listing
 * that changed.
 */
export function keepUnchangedApps(previous: readonly CatalogApp[], next: readonly CatalogApp[]): CatalogApp[] {
  if (previous.length === 0) return next as CatalogApp[];
  const held = new Map(previous.map((app) => [app.id, app]));
  return next.map((app) => {
    const old = held.get(app.id);
    return old && sameApp(old, app) ? old : app;
  });
}

function sameApp(a: CatalogApp, b: CatalogApp): boolean {
  const keys = Object.keys(a) as (keyof CatalogApp)[];
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => {
    const x = a[key];
    const y = b[key];
    if (x === y) return true;
    if (Array.isArray(x) && Array.isArray(y)) return x.length === y.length && x.every((item, i) => item === y[i]);
    if (key === "icon" && x && y && typeof x === "object" && typeof y === "object") {
      const [p, q] = [x as AppIconRef, y as AppIconRef];
      return p.path === q.path && p.asset === q.asset && p.symbol === q.symbol;
    }
    return false;
  });
}

/** Discover's catalog grid: a card is at least this wide, and cards and rows are this far apart
 *  (styles.css `.apps-grid`). The windowed grid counts its columns the way `auto-fill` does. */
export const GRID_CARD_MIN = 260;
export const GRID_GAP = 14;
/** The list layout's rows are this far apart (styles.css `.apps-rows`). */
export const LIST_GAP = 2;
/** A grid row's and a list row's height before the first of its kind is measured. */
export const GRID_ROW_ESTIMATE = 150;
export const LIST_ROW_ESTIMATE = 56;

/** The columns `repeat(auto-fill, minmax(min(100%, 260px), 1fr))` makes in `width` px. */
export function gridColumns(width: number): number {
  if (!(width > GRID_CARD_MIN)) return 1;
  return Math.max(1, Math.floor((width + GRID_GAP) / (GRID_CARD_MIN + GRID_GAP)));
}

/** The windowed catalog: its rows (`columns` listings each), and each listing's row, built once per
 *  catalog or column count. A row whose listings are all the ones `previous` held keeps its array,
 *  so its memoized row component does not draw again. */
export interface CatalogRows {
  rows: CatalogApp[][];
  /** Listing id to its row index: a selection or focus finds its row without a scan. */
  rowOf: Map<string, number>;
}

export function catalogRows(apps: readonly CatalogApp[], columns: number, previous?: CatalogRows): CatalogRows {
  const rows: CatalogApp[][] = [];
  const rowOf = new Map<string, number>();
  for (let start = 0; start < apps.length; start += columns) {
    const index = rows.length;
    const fresh = apps.slice(start, start + columns);
    const old = previous ? previous.rows[previous.rowOf.get(fresh[0]!.id) ?? -1] : undefined;
    rows.push(old && old.length === fresh.length && old.every((app, i) => app === fresh[i]) ? old : fresh);
    for (const app of fresh) rowOf.set(app.id, index);
  }
  return { rows, rowOf };
}

/** Categories present in the catalog, in first-seen order. */
export function categories(apps: readonly CatalogApp[]): string[] {
  const seen = new Set<string>();
  for (const app of apps) for (const category of app.categories) seen.add(category);
  return [...seen];
}

export const TierLabel: Record<AppTier, string> = {
  "first-party": "store.tier.firstParty",
  verified: "store.tier.verified",
  unverified: "store.tier.unverified",
};

const CATEGORY_KEYS: Record<string, string> = {
  sidebar: "store.category.sidebar",
  agents: "store.category.agents",
  git: "store.category.git",
  productivity: "store.category.productivity",
  monitoring: "store.category.monitoring",
  themes: "store.category.themes",
  browser: "store.category.browser",
  cloud: "store.category.cloud",
  "developer-tools": "store.category.developerTools",
  fun: "store.category.fun",
};

/** A category's label: its string key when known, else the id itself. */
export function categoryLabel(id: string, t: (key: string) => string): string {
  const key = CATEGORY_KEYS[id];
  return key ? t(key) : id;
}

/** Risk classes shown first in the permissions list: restricted, then sensitive, then standard. */
const RISK_ORDER: ScopeRisk[] = ["restricted", "sensitive", "standard"];

/** Required scopes before optional ones, then by risk, then by name. */
export function orderScopes<T extends { scope: string; risk: ScopeRisk; optional: boolean }>(
  scopes: readonly T[],
): T[] {
  return [...scopes].sort(
    (a, b) =>
      Number(a.optional) - Number(b.optional) ||
      RISK_ORDER.indexOf(a.risk) - RISK_ORDER.indexOf(b.risk) ||
      (a.scope < b.scope ? -1 : a.scope > b.scope ? 1 : 0),
  );
}

/** Sandboxed apps get no network or integration scopes; those rows show dimmed (Swift AppGrantsView). */
export function dimmedWhenSandboxed(row: GrantRow): boolean {
  return row.scope.startsWith("net:") || row.scope.startsWith("integration:");
}

/** Initials for an app with no image and no host glyph (no SF Symbols on the web; coordinator Q5). */
export { initials } from "../../ui/initials";
