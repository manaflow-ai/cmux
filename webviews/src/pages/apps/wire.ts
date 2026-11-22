// The owner's `cmux.apps/1` shapes (apps lane, cmux-tui-core store.rs) and their mapping to the
// page's view types. Only this file knows the wire field names; the generated client replaces the
// wire types when it lands. Listing text is English until the owner localizes (later request).
import type { PageClient } from "../shared/pageClient";
import {
  AppsOps,
  type AppDetail,
  type AppSource,
  type AppTier,
  type AppVersion,
  type CatalogApp,
  type CatalogListResult,
  type InstalledApp,
  type ScopeRequest,
} from "./types";

export interface WireInstallState {
  installed: boolean;
  enabled: boolean;
  hidden: boolean;
  sandboxed: boolean;
  source: AppSource;
  version: string | null;
  update: { version: string } | null;
}

export type WireIcon = { asset: string } | { symbol: string } | null;

export interface WireListing {
  app: string;
  name: string;
  summary: string;
  publisher: string;
  tier: AppTier;
  version: string;
  icon: WireIcon;
  categories: string[];
  keywords?: string[];
  hide_only: boolean;
  install: WireInstallState | null;
}

/** `cmux.apps.catalog.get`: a listing plus what the detail and the native sheets need. */
export interface WireDetail extends WireListing {
  scopes: ScopeRequest[];
  versions?: AppVersion[];
  repository?: string;
  screenshots?: string[];
}

export interface WireCatalogPage {
  listings: WireListing[];
  next_cursor: string | null;
  revision: number;
}

export interface WireInstalledApp {
  app: string;
  name: string;
  tier: AppTier;
  hide_only: boolean;
  state: WireInstallState;
  grants: unknown[];
}

export interface WireInstalledList {
  revision: number;
  apps: WireInstalledApp[];
}

/** The page asks for the owner's largest page and follows the cursor. */
export const CATALOG_PAGE = 200;

export function fromListing(listing: WireListing): CatalogApp {
  return {
    id: listing.app,
    name: listing.name,
    description: listing.summary,
    publisher: listing.publisher,
    // Verification is the tier's job on this wire; first-party and verified both show as verified.
    publisher_verified: listing.tier !== "unverified",
    tier: listing.tier,
    categories: listing.categories,
    keywords: listing.keywords,
    latest_version: listing.version,
    install_count: 0,
    // An asset path needs cmux.apps.asset.get (not served yet); a symbol is never drawn on the web.
    icon: undefined,
    installed: listing.install?.installed === true,
    enabled: listing.install?.enabled,
    hidden: listing.install?.hidden,
    hide_only: listing.hide_only,
  };
}

export function fromDetail(detail: WireDetail): AppDetail {
  return {
    ...fromListing(detail),
    scopes: detail.scopes ?? [],
    versions: detail.versions ?? [],
    repository: detail.repository,
    screenshots: detail.screenshots ?? [],
  };
}

export function fromInstalled(row: WireInstalledApp): InstalledApp {
  return {
    id: row.app,
    name: row.name,
    version: row.state.version ?? "",
    enabled: row.state.enabled,
    hidden: row.state.hidden,
    sandboxed: row.state.sandboxed,
    source: row.state.source,
    tier: row.tier,
    hide_only: row.hide_only,
    update: row.state.update ?? undefined,
  };
}

/** Every listing, page by page (`limit` 200, then `cursor` until `next_cursor` is null). */
export async function listCatalog(client: Pick<PageClient, "call">): Promise<CatalogListResult> {
  const apps: CatalogApp[] = [];
  let cursor: string | null = null;
  let revision = 0;
  do {
    const params: Record<string, unknown> = cursor ? { limit: CATALOG_PAGE, cursor } : { limit: CATALOG_PAGE };
    const page: WireCatalogPage = await client.call<WireCatalogPage>(AppsOps.catalogList, params);
    apps.push(...page.listings.map(fromListing));
    revision = page.revision;
    cursor = page.next_cursor;
  } while (cursor);
  return { apps, revision };
}

export async function listInstalled(
  client: Pick<PageClient, "call">,
): Promise<{ apps: InstalledApp[]; revision: number }> {
  const list = await client.call<WireInstalledList>(AppsOps.installedList, {});
  return { apps: list.apps.map(fromInstalled), revision: list.revision };
}
