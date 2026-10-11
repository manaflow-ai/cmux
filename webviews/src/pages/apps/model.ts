// Pure presentation model of the App Store page (plans/cmux-next/react-pages.md 3.3). Catalog
// semantics (tiers, install states, grants) belong to the app platform lead's owner; this file
// only filters, orders and labels what the owner returns.
import { APP_STORE_ID, type AppTier, type CatalogApp, type GrantRow, type ScopeRisk } from "./types";

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

/** The page's route from its URL fragment: `#/discover?layout=list&app=<id>`, `#/installed`. */
export interface StoreRoute {
  tab: StoreTab;
  layout: StoreLayout;
  app?: string;
}

export function parseRoute(hash: string): StoreRoute {
  const text = hash.replace(/^#/, "");
  const [path, query = ""] = text.split("?", 2);
  const params = new URLSearchParams(query);
  return {
    tab: path.replace(/^\//, "") === "installed" ? "installed" : "discover",
    layout: parseLayout(params.get("layout")),
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

/** Whether the page shows `app` at all: the App Store never lists itself (FIRST-PARTY-APPS). */
export function listedInStore(app: { id: string }): boolean {
  return app.id !== APP_STORE_ID;
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

/** Initials for the generic icon glyph (no SF Symbols on the web; coordinator Q5). */
export function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words[1][0] : (words[0] ?? "?").slice(0, 2);
  return letters.toLocaleUpperCase();
}
