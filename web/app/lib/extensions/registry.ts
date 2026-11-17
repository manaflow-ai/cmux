import { cacheLife } from "next/cache";
import { GITHUB_HOST, type ListingKey, type ListingKind, installReference } from "./refs";

/**
 * The public extension registry (cmux-platform, contract.md "Registry API").
 * Only approved listings are served, each pinned to its reviewed commit.
 *
 * `CMUX_REGISTRY_URL` points the site at another registry (staging, a local
 * worker). Every read here fails soft: an unreachable registry shows the
 * how-to-list state on the index and a short-lived 404 on a page, never an error page.
 */
export const DEFAULT_REGISTRY_URL = "https://cmux-platform-production.debussy.workers.dev";
const REGISTRY_TIMEOUT_MS = 8_000;
const PAGE_LIMIT = 100;
/** Bound on pages walked for the sitemap and author pages: 50 x 100 listings. */
const MAX_PAGES = 50;

export function registryBaseUrl(env: Record<string, string | undefined> = process.env): string {
  const configured = env.CMUX_REGISTRY_URL?.trim();
  return (configured || DEFAULT_REGISTRY_URL).replace(/\/+$/, "");
}

/**
 * The tier a listing belongs to (contract.md "Obsidian model" C): a plugin runs code in the
 * sandboxed app host; a theme and a snippet are files with no code; a setup is a whole customization.
 */
export type ListingTier = "plugin" | "theme" | "snippet" | "setup";
export const LISTING_TIERS: readonly ListingTier[] = ["plugin", "theme", "snippet", "setup"];

export type ListingRelease = { version: string; tag?: string; date?: string };

export type Listing = ListingKey & {
  kind: ListingKind;
  tier: ListingTier;
  repository: string;
  id: string;
  name: string;
  tagline?: string;
  description: string;
  categories: string[];
  iconUrl?: string;
  screenshots: string[];
  license?: string;
  publisher?: string;
  publisherUrl?: string;
  commit: string;
  /** Latest release (manifest version, release tag and date), when the repo has one. */
  latest?: ListingRelease;
  reviewedAt?: string;
  updatedAt?: string;
  stars?: number;
  installs?: number;
  /** Install pings plus release asset downloads (contract.md "Obsidian model" E); falls back to installs. */
  downloads?: number;
  /** Minimum cmux version (manifest `engines.cmux`), shown as "Requires cmux X or later". */
  requiresCmux?: string;
  readme: string;
  /** What a setup installs, by kind of item (theme, sidebar, keymap, widgets, extensions...). */
  contents: SetupItem[];
};

export type SetupItem = { kind: string; name: string; ref?: string };

export type ListingPage = { items: Listing[]; next?: string };

function text(value: unknown, max = 2_000): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, max) : undefined;
}

function count(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.floor(value) : undefined;
}

/** An https URL, or undefined: listing media never loads from anywhere else. */
export function httpsUrl(value: unknown): string | undefined {
  const raw = text(value, 2_048);
  if (!raw) return undefined;
  try {
    const url = new URL(raw);
    return url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

const SHA_PATTERN = /^[0-9a-f]{40}$/;
const VERSION_PATTERN = /^[0-9]+(?:\.[0-9]+){0,3}(?:-[0-9A-Za-z.-]+)?$/;

function requiredVersion(record: Record<string, unknown>): string | undefined {
  const engines = record.engines as Record<string, unknown> | undefined;
  const raw = text(record.minCmux, 40) ?? text(record.requiresCmux, 40) ?? text(engines?.cmux, 40);
  // engines.cmux is a minimum: `^2.0`, `>=0.70.0` or a bare version all read as "this version or later".
  const version = raw?.replace(/^(?:>=|\^|~)\s*/, "");
  return version && VERSION_PATTERN.test(version) ? version : undefined;
}

function stringList(value: unknown, max = 100): string[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, max).flatMap((item) => (text(item, 300) ? [text(item, 300)!] : []));
}

/**
 * What a setup installs. The registry sends either `contents` rows, or the setup's own summary
 * (setups.md): `changes: { settings, files, actions }` and `extensions` references.
 */
function setupItems(record: Record<string, unknown>): SetupItem[] {
  if (Array.isArray(record.contents)) return contentRows(record.contents);
  const changes = (record.changes ?? {}) as Record<string, unknown>;
  const rows: SetupItem[] = [];
  for (const file of stringList(changes.files)) rows.push({ kind: fileKind(file), name: file });
  for (const key of stringList(changes.settings)) rows.push({ kind: "setting", name: key });
  for (const name of stringList(changes.actions)) rows.push({ kind: "action", name });
  for (const ref of stringList(record.extensions)) {
    rows.push({ kind: "extension", name: ref.replace(/@.*$/, "").split("/").slice(-1)[0] ?? ref, ref });
  }
  return rows.slice(0, 200);
}

/** A setup file's kind, from its customize logical path (setups.md "Files"). */
function fileKind(path: string): string {
  if (path === "keybindings.json") return "keymap";
  if (path.startsWith("themes/")) return "theme";
  if (path.startsWith("customize/")) return "view";
  if (path.endsWith(".css")) return "style";
  return "file";
}

function contentRows(value: unknown[]): SetupItem[] {
  return value.slice(0, 200).flatMap((item) => {
    if (typeof item !== "object" || item === null) return [];
    const record = item as Record<string, unknown>;
    const kind = text(record.kind, 40);
    const name = text(record.name, 120);
    if (!kind || !name) return [];
    const ref = text(record.ref, 300);
    return [{ kind, name, ...(ref ? { ref } : {}) }];
  });
}

function tierOf(record: Record<string, unknown>, kind: ListingKind): ListingTier {
  if (kind === "setup" || record.kind === "setup") return "setup";
  const tier = record.tier ?? record.type;
  return tier === "theme" || tier === "snippet" ? tier : "plugin";
}

/** The newest release: `latest`, else `version` with the first of `versions` (newest first). */
function latestRelease(record: Record<string, unknown>): ListingRelease | undefined {
  const versions = Array.isArray(record.versions) ? (record.versions as unknown[]) : [];
  const first = (versions[0] ?? record.latest ?? {}) as Record<string, unknown>;
  const version = text(record.version, 40) ?? text(first.version, 40);
  if (!version) return undefined;
  const tag = text(first.tag, 80);
  const date = text(first.date, 40) ?? text(first.publishedAt, 40);
  return { version, ...(tag ? { tag } : {}), ...(date ? { date } : {}) };
}

/** `publisher` is `{ name, url? }` in the registry; a plain string is read too. */
function publisherOf(record: Record<string, unknown>): { publisher?: string; publisherUrl?: string } {
  const value = record.publisher ?? record.author;
  if (typeof value === "string") return { publisher: text(value, 120) };
  if (typeof value !== "object" || value === null) return {};
  const object = value as Record<string, unknown>;
  return { publisher: text(object.name, 120), publisherUrl: httpsUrl(object.url) };
}

/** The fields every page needs, or null when one is missing or malformed. */
function requiredFields(json: unknown): { record: Record<string, unknown>; owner: string; repo: string; name: string; commit: string } | null {
  if (typeof json !== "object" || json === null) return null;
  const record = json as Record<string, unknown>;
  const owner = text(record.owner, 100);
  const repo = text(record.repo, 100);
  const name = text(record.name, 120);
  const commit = text(record.commit, 40);
  if (!owner || !repo || !name || !commit || !SHA_PATTERN.test(commit)) return null;
  return { record, owner, repo, name, commit };
}

function httpsList(value: unknown, max: number): string[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => (httpsUrl(item) ? [httpsUrl(item)!] : [])).slice(0, max);
}

/** One listing from the registry's JSON, or null when it lacks what a page needs. */
export function parseListing(json: unknown, kind: ListingKind = "extension"): Listing | null {
  const required = requiredFields(json);
  if (!required) return null;
  const { record, owner, repo, name, commit } = required;
  const host = text(record.host, 253)?.toLowerCase() ?? GITHUB_HOST;
  const path = (text(record.path, 500) ?? "").replace(/^\/+|\/+$/g, "");
  const categories = stringList(record.categories, 10).map((category) => category.slice(0, 40));
  const screenshots = httpsList(record.screenshots, 10);
  const listing: Listing = {
    kind: record.kind === "setup" ? "setup" : kind,
    tier: tierOf(record, kind),
    host,
    owner,
    repo,
    path,
    repository: text(record.repository, 500) ?? `${host}/${owner}/${repo}`,
    id: text(record.id, 200) ?? `${owner.toLowerCase()}/${repo}`,
    name,
    description: text(record.description, 1_000) ?? "",
    categories,
    screenshots,
    commit,
    readme: typeof record.readme === "string" ? record.readme.slice(0, 200_000) : "",
    contents: setupItems(record),
  };
  const optional: Partial<Listing> = {
    tagline: text(record.tagline, 160),
    iconUrl: httpsUrl(record.iconUrl),
    license: text(record.license, 80),
    ...publisherOf(record),
    latest: latestRelease(record),
    reviewedAt: text(record.reviewedAt, 40),
    updatedAt: text(record.updatedAt, 40),
    stars: count(record.stars),
    installs: count(record.installs),
    downloads: count(record.downloads) ?? count(record.installs),
    requiresCmux: requiredVersion(record),
  };
  for (const [field, value] of Object.entries(optional)) {
    if (value !== undefined) (listing as Record<string, unknown>)[field] = value;
  }
  return listing;
}

export function parseListingPage(json: unknown, kind: ListingKind = "extension"): ListingPage {
  const record = (json ?? {}) as Record<string, unknown>;
  if (!Array.isArray(record.items)) throw new Error("the registry page has no items");
  const items = record.items.flatMap((item) => {
    const listing = parseListing(item, kind);
    return listing ? [listing] : [];
  });
  const next = text(record.next, 500);
  return next ? { items, next } : { items };
}

const COLLECTION: Record<ListingKind, string> = { extension: "/v1/extensions", setup: "/v1/setups" };

async function registryJson(path: string): Promise<{ status: number; body: unknown }> {
  const response = await fetch(`${registryBaseUrl()}${path}`, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS),
  });
  if (response.status === 404) return { status: 404, body: null };
  if (!response.ok) throw new Error(`the registry returned HTTP ${response.status} for ${path}`);
  return { status: response.status, body: await response.json() };
}

/**
 * The registry path for one listing: `/OWNER/REPO` for a GitHub repo root, else
 * `/by-ref?ref=HOST/OWNER/REPO[/PATH]` (registry.md "Public routes").
 */
export function registryListingPath(key: ListingKey): string {
  if (key.host === GITHUB_HOST && !key.path) return `/${encodeURIComponent(key.owner)}/${encodeURIComponent(key.repo)}`;
  return `/by-ref?${new URLSearchParams({ ref: installReference(key) }).toString()}`;
}

/** One page of approved listings. Throws when the registry cannot answer; a failure is not cached. */
export async function fetchListingPage(
  kind: ListingKind,
  options: { cursor?: string; category?: string } = {},
): Promise<ListingPage> {
  "use cache";
  cacheLife({ stale: 60, revalidate: 300, expire: 3_600 });
  const query = new URLSearchParams({ limit: String(PAGE_LIMIT) });
  if (options.cursor) query.set("cursor", options.cursor);
  if (options.category) query.set("category", options.category);
  const { body } = await registryJson(`${COLLECTION[kind]}?${query.toString()}`);
  return parseListingPage(body, kind);
}

/** Every approved listing of a kind, bounded by MAX_PAGES. */
export async function fetchAllListings(kind: ListingKind): Promise<Listing[]> {
  const listings: Listing[] = [];
  let cursor: string | undefined;
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const result = await fetchListingPage(kind, { cursor });
    listings.push(...result.items);
    if (!result.next || result.next === cursor) break;
    cursor = result.next;
  }
  return listings;
}

/** An author's approved listings of both kinds (`GET /v1/authors/:name`), or [] when they have none. */
export async function fetchAuthorListings(owner: string, host = GITHUB_HOST): Promise<Listing[]> {
  "use cache";
  cacheLife({ stale: 60, revalidate: 300, expire: 3_600 });
  const { status, body } = await registryJson(`/v1/authors/${encodeURIComponent(owner)}?${new URLSearchParams({ host })}`);
  if (status === 404) return [];
  const items = (body as { items?: unknown } | null)?.items;
  if (!Array.isArray(items)) throw new Error("the registry author has no items");
  return items.flatMap((item) => {
    const listing = parseListing(item);
    // Only ever the owner's own listings, whatever the registry sends.
    return listing && listing.owner.toLowerCase() === owner.toLowerCase() ? [listing] : [];
  });
}

/**
 * One approved listing, or null when the registry has none for it. A missing
 * listing is cached for a minute only, so a newly approved repo shows up fast.
 */
export async function fetchListing(kind: ListingKind, key: ListingKey): Promise<Listing | null> {
  "use cache";
  const { status, body } = await registryJson(`${COLLECTION[kind]}${registryListingPath(key)}`);
  if (status === 404) {
    cacheLife({ stale: 30, revalidate: 60, expire: 300 });
    return null;
  }
  cacheLife({ stale: 60, revalidate: 300, expire: 3_600 });
  return parseListing(body, kind);
}

/** Like fetchListing, but an unreachable registry reads as "no listing" (the page 404s, briefly). */
export async function loadListing(kind: ListingKind, key: ListingKey): Promise<Listing | null> {
  try {
    return await fetchListing(kind, key);
  } catch (error) {
    console.error("extensions.registry_unavailable", error);
    return null;
  }
}

/** Like fetchAllListings, but null when the registry is unreachable. */
export async function loadAllListings(kind: ListingKind): Promise<Listing[] | null> {
  try {
    return await fetchAllListings(kind);
  } catch (error) {
    console.error("extensions.registry_unavailable", error);
    return null;
  }
}

/** Like fetchAuthorListings, but null when the registry is unreachable. */
export async function loadAuthorListings(owner: string): Promise<Listing[] | null> {
  try {
    return await fetchAuthorListings(owner);
  } catch (error) {
    console.error("extensions.registry_unavailable", error);
    return null;
  }
}
