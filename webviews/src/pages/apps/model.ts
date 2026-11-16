// Pure presentation model of the App Store page (plans/cmux-next/react-pages.md 3.3). Catalog
// semantics (tiers, install states, grants) belong to the app platform lead's owner; this file
// only filters, orders and labels what the owner returns.
import { APP_STORE_ID, HOME_ID, type AppTier, type CatalogApp, type GrantRow, type ScopeRisk } from "./types";

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

/**
 * The shelf Discover shows (the owner's `Shelf`, cmux-tui-core apps/store.rs): `store` is the
 * first-party apps cmux ships (Cloud, CodeRouter); `example` the SDK examples, offered only when
 * the owner says so (developer mode, or a `cmux ext dev` app). A `local` listing (`cmux ext dev`)
 * is never on Discover: Installed shows it as Local (dev).
 */
export type DiscoverShelf = "store" | "example";

/** Whether `app` is on `shelf`; a listing from an owner older than shelves is on the store shelf. */
export function onShelf(app: { shelf?: string }, shelf: DiscoverShelf): boolean {
  return (app.shelf ?? "store") === shelf;
}

/**
 * Where Discover offers the Examples shelf (`examples=` in the route, like `card=`): `chip` is the
 * default, an Examples filter after the categories; `tab` and `section` are DEV variants shown in
 * the gallery (a third toolbar tab; a section under the store's apps).
 */
export type ExamplesStyle = "chip" | "tab" | "section";

export function parseExamplesStyle(value: string | null | undefined): ExamplesStyle {
  return value === "tab" || value === "section" ? value : "chip";
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
  examples: ExamplesStyle;
  /** `shelf=examples` opens Discover on the Examples shelf (when the owner offers it). */
  shelf: DiscoverShelf;
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
    examples: parseExamplesStyle(params.get("examples")),
    shelf: params.get("shelf") === "examples" ? "example" : "store",
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

export function filterApps(
  apps: readonly CatalogApp[],
  query: string,
  category: string | undefined,
  shelf: DiscoverShelf = "store",
): CatalogApp[] {
  return apps.filter(
    (app) => onShelf(app, shelf) && (!category || app.categories.includes(category)) && matches(app, query),
  );
}

/** Categories present on `shelf` of the catalog, in first-seen order. */
export function categories(apps: readonly CatalogApp[], shelf: DiscoverShelf = "store"): string[] {
  const seen = new Set<string>();
  for (const app of apps) if (onShelf(app, shelf)) for (const category of app.categories) seen.add(category);
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
