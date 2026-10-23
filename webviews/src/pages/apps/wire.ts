// The owner's `cmux.apps/1` shapes (apps lane, cmux-tui-core store.rs) and their mapping to the
// page's view types. Only this file knows the wire field names; the generated client replaces the
// wire types when it lands. Listing text is English until the owner localizes (later request).
import type { PageClient } from "../shared/pageClient";
import {
  AppsOps,
  type AppContribution,
  type AppDetail,
  type AppIconRef,
  type AppSource,
  type AppTier,
  type AppVersion,
  type AppUpdate,
  type CatalogApp,
  type CatalogListResult,
  type InstalledApp,
  type ScopeRequest,
  type UpdatesListResult,
} from "./types";

export interface WireInstallState {
  installed: boolean;
  enabled: boolean;
  hidden: boolean;
  sandboxed: boolean;
  source: AppSource;
  version: string | null;
  update: { version: string } | null;
  failure?: string | null;
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
  /** The manifest's contributions; the owner's `catalog.get` does not send them yet. */
  contributes?: AppContribution[];
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

/** `cmux.apps.updates.list`: only updates the supervisor currently knows about. */
export interface WireUpdate {
  app: string;
  name?: string;
  current_version?: string;
  version: string;
  failure?: string | null;
}

export interface WireUpdatesList {
  revision: number;
  updates: WireUpdate[];
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
    // The store loads an asset through cmux.apps.asset.get; a symbol is the host's own drawing
    // of it (`glyph/<symbol>`), never Apple's symbol.
    icon: wireIcon(listing.icon),
    installed: listing.install?.installed === true,
    enabled: listing.install?.enabled,
    hidden: listing.install?.hidden,
    hide_only: listing.hide_only,
  };
}

function wireIcon(icon: WireIcon): AppIconRef | undefined {
  if (!icon) return undefined;
  if ("asset" in icon) return { asset: icon.asset };
  return icon.symbol ? { symbol: icon.symbol } : undefined;
}

/** The owner's contributions, keeping only entries with a string kind and a non-blank title. */
function contributionsFrom(value: unknown): AppContribution[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter(
    (item): item is AppContribution =>
      typeof item?.kind === "string" && typeof item.title === "string" && item.title.trim() !== "",
  );
}

export function fromDetail(detail: WireDetail): AppDetail {
  return {
    ...fromListing(detail),
    scopes: detail.scopes ?? [],
    versions: detail.versions ?? [],
    repository: detail.repository,
    screenshots: detail.screenshots ?? [],
    contributes: contributionsFrom(detail.contributes),
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
    failure: row.state.failure ?? undefined,
  };
}

export function fromUpdate(row: WireUpdate): AppUpdate {
  return {
    app: row.app,
    name: row.name,
    current_version: row.current_version,
    version: row.version,
    failure: row.failure ?? undefined,
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

export async function listUpdates(client: Pick<PageClient, "call">): Promise<UpdatesListResult> {
  const list = await client.call<WireUpdatesList>(AppsOps.updatesList, {});
  return { updates: list.updates.map(fromUpdate), revision: list.revision };
}
