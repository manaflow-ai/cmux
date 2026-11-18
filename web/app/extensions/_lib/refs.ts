/**
 * Where an extension or setup lives, and the cmux.com URLs that name it.
 *
 * A listing is keyed by (host, owner, repo, path): path is the directory in the
 * repo that holds the manifest, "" for the repo root. GitHub repos keep the
 * short page form `/extensions/OWNER/REPO[/PATH...]`; any other host is spelled
 * out, `/extensions/HOST/OWNER/REPO[/PATH...]`. A GitHub owner never contains a
 * dot, so a first segment with a dot is always a host.
 */

export const SITE = "https://cmux.com";
export const GITHUB_HOST = "github.com";

export type ListingKind = "extension" | "setup";

/** The page root each kind of listing lives under. */
export const KIND_ROOT: Record<ListingKind, string> = {
  extension: "/extensions",
  setup: "/setups",
};

export type ListingKey = {
  host: string;
  owner: string;
  repo: string;
  /** Directory of the manifest inside the repo, no leading or trailing slash; "" for the root. */
  path: string;
};

/** Which page of a listing a URL names: the listing, its install page or its remix page. */
export type ListingPage = "listing" | "install" | "remix";

export type ListingRoute = ListingKey & {
  page: ListingPage;
};

const HOST_PATTERN = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;
const NAME_PATTERN = /^(?!\.+$)[A-Za-z0-9._-]{1,100}$/;
const PATH_SEGMENT_PATTERN = /^(?!\.+$)[A-Za-z0-9._@+-]{1,100}$/;
const MAX_PATH_SEGMENTS = 8;
const SHA_PATTERN = /^[0-9a-f]{40}$/;

export function isValidOwner(value: string): boolean {
  return NAME_PATTERN.test(value);
}

/** Whether a key names a host, owner, repo and folder the page URLs can carry as they are. */
export function isValidKey(key: ListingKey): boolean {
  const parts = key.path ? key.path.split("/") : [];
  return (
    HOST_PATTERN.test(key.host) &&
    NAME_PATTERN.test(key.owner) &&
    NAME_PATTERN.test(key.repo) &&
    parts.length <= MAX_PATH_SEGMENTS &&
    parts.every((part) => PATH_SEGMENT_PATTERN.test(part))
  );
}

function decodeSegment(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/**
 * Reads a catch-all page's segments into a listing route, or null when they
 * cannot name one. A trailing `install` or `remix` segment selects that page, so a manifest
 * folder named `install` or `remix` has no page of its own.
 */
export function parseListingSlug(slug: readonly string[]): ListingRoute | null {
  const segments: string[] = [];
  for (const raw of slug) {
    const decoded = decodeSegment(raw);
    if (decoded === null) return null;
    segments.push(decoded);
  }
  let page: ListingPage = "listing";
  const last = segments[segments.length - 1];
  if (segments.length >= 3 && (last === "install" || last === "remix")) {
    page = last;
    segments.pop();
  }
  let host = GITHUB_HOST;
  if (segments.length >= 3 && segments[0]!.includes(".")) {
    host = segments.shift()!.toLowerCase();
    if (!HOST_PATTERN.test(host)) return null;
    // github.com spelled out is the short form's page.
  }
  const [owner, repo, ...rest] = segments;
  if (!owner || !repo || !NAME_PATTERN.test(owner) || !NAME_PATTERN.test(repo)) return null;
  if (rest.length > MAX_PATH_SEGMENTS || !rest.every((part) => PATH_SEGMENT_PATTERN.test(part))) return null;
  return { host, owner, repo, path: rest.join("/"), page };
}

function encodePath(parts: readonly string[]): string {
  return parts.map((part) => encodeURIComponent(part)).join("/");
}

function keyParts(key: ListingKey): string[] {
  const parts = key.host === GITHUB_HOST ? [] : [key.host];
  parts.push(key.owner, key.repo);
  if (key.path) parts.push(...key.path.split("/"));
  return parts;
}

/** The site path of a listing's page, e.g. `/extensions/OWNER/REPO`. */
export function listingPath(key: ListingKey, kind: ListingKind = "extension"): string {
  return `${KIND_ROOT[kind]}/${encodePath(keyParts(key))}`;
}

export function listingUrl(key: ListingKey, kind: ListingKind = "extension"): string {
  return `${SITE}${listingPath(key, kind)}`;
}

export function installPath(key: ListingKey, kind: ListingKind = "extension"): string {
  return `${listingPath(key, kind)}/install`;
}

/** The install reference the app reads: `HOST/OWNER/REPO[/PATH]`. */
export function installReference(key: ListingKey): string {
  return [key.host, key.owner, key.repo, ...(key.path ? [key.path] : [])].join("/");
}

/**
 * The app's install link: `cmux://apps/install?repo=HOST/OWNER/REPO[/PATH]&commit=SHA`
 * (contract.md "Deeplink"). A setup uses `cmux://setups/install` with the same query.
 */
export function installDeeplink(key: ListingKey, commit?: string | null, kind: ListingKind = "extension"): string {
  const query = new URLSearchParams({ repo: installReference(key) });
  if (commit && SHA_PATTERN.test(commit)) query.set("commit", commit);
  const target = kind === "setup" ? "setups/install" : "apps/install";
  return `cmux://${target}?${query.toString().replace(/\+/g, "%20")}`;
}

/**
 * The download page that remembers what to install (contract.md "Additions" 4, install.md "Handoff"):
 * `/download?install=HOST/OWNER/REPO[/PATH][&commit=SHA]` starts the download, keeps the reference in
 * its URL, and offers (and retries on focus) the install link once cmux is on the Mac.
 */
export function downloadWithInstallHref(key: ListingKey, commit?: string | null, kind: ListingKind = "extension"): string {
  const query = new URLSearchParams({ install: installReference(key) });
  if (commit && SHA_PATTERN.test(commit)) query.set("commit", commit);
  if (kind === "setup") query.set("kind", "setup");
  return `/download?${query.toString()}`;
}

/** Reads `install=HOST/OWNER/REPO[/PATH]` (an optional `https://` and trailing `@REF` are dropped) into a key. */
export function parseInstallReference(value: string): ListingKey | null {
  const trimmed = value.trim().replace(/^https:\/\//i, "").replace(/\.git$/i, "").replace(/@[^/]*$/, "");
  const segments = trimmed.split("/").filter(Boolean);
  if (segments.length < 3 || !segments[0]!.includes(".")) return null;
  const route = parseListingSlug(segments.map(encodeURIComponent));
  if (!route || route.page !== "listing") return null;
  return { host: route.host, owner: route.owner, repo: route.repo, path: route.path };
}

/** The app's remix link (remix.md): `cmux://build?remix=HOST/OWNER/REPO[/PATH]@COMMIT`. */
export function remixDeeplink(key: ListingKey, commit: string): string {
  const reference = SHA_PATTERN.test(commit) ? `${installReference(key)}@${commit}` : installReference(key);
  return `cmux://build?${new URLSearchParams({ remix: reference }).toString()}`;
}

export function remixPath(key: ListingKey, kind: ListingKind = "extension"): string {
  return `${listingPath(key, kind)}/remix`;
}

/** The repository's web URL. */
export function repositoryUrl(key: ListingKey): string {
  return `https://${key.host}/${encodePath([key.owner, key.repo])}`;
}

/**
 * The repository's tree (or blob, for a file) at `commit`, under the listing's
 * path. GitHub, GitLab and Codeberg have stable forms; other hosts get the repo URL.
 */
export function repositoryTreeUrl(key: ListingKey, commit: string, file = "", kind: "tree" | "blob" = "tree"): string {
  const base = repositoryUrl(key);
  const inner = [key.path, file].filter(Boolean).join("/");
  const suffix = inner ? `/${inner.split("/").map(encodeURIComponent).join("/")}` : "";
  if (key.host === GITHUB_HOST) return `${base}/${kind}/${commit}${suffix}`;
  if (key.host === "gitlab.com") return `${base}/-/${kind}/${commit}${suffix}`;
  if (key.host === "codeberg.org") return `${base}/src/commit/${commit}${suffix}`;
  return base;
}

/** The raw file URL at `commit` (for images a README links relatively). */
export function repositoryRawUrl(key: ListingKey, commit: string, file: string): string | null {
  const inner = [key.path, file].filter(Boolean).join("/").split("/").map(encodeURIComponent).join("/");
  const ownerRepo = encodePath([key.owner, key.repo]);
  if (key.host === GITHUB_HOST) return `https://raw.githubusercontent.com/${ownerRepo}/${commit}/${inner}`;
  if (key.host === "gitlab.com") return `https://gitlab.com/${ownerRepo}/-/raw/${commit}/${inner}`;
  if (key.host === "codeberg.org") return `https://codeberg.org/${ownerRepo}/raw/commit/${commit}/${inner}`;
  return null;
}

/** The README snippet a publisher pastes (contract.md "Badge"), for this listing's page. */
export function badgeSnippet(key: ListingKey, kind: ListingKind = "extension"): string {
  return `[![Get it on cmux](${SITE}/extensions/badge.svg)](${listingUrl(key, kind)})`;
}

/**
 * The site's author page for a listing's owner, `/u/NAME`. Author pages are GitHub
 * accounts (the registry's /v1/authors is keyed by GitHub login), so an owner on
 * another host has none: the same name there may be a different person.
 */
export function authorPath(key: Pick<ListingKey, "host" | "owner">): string | null {
  if (key.host !== GITHUB_HOST) return null;
  return `/u/${encodeURIComponent(key.owner)}`;
}

/** The owner's profile on their own host, e.g. `https://gitlab.com/OWNER`. */
export function ownerProfileUrl(key: Pick<ListingKey, "host" | "owner">): string {
  return `https://${key.host}/${encodeURIComponent(key.owner)}`;
}

/** Where a listing's author name links: the site's author page on GitHub, else the owner's profile on their host. */
export function authorHref(key: Pick<ListingKey, "host" | "owner">): { href: string; external: boolean } {
  const path = authorPath(key);
  return path ? { href: path, external: false } : { href: ownerProfileUrl(key), external: true };
}

/** A release's page on its host, or the repository when the host has no stable release URL. */
export function releaseUrl(key: ListingKey, tag: string): string {
  const base = repositoryUrl(key);
  const encoded = encodeURIComponent(tag);
  if (key.host === GITHUB_HOST) return `${base}/releases/tag/${encoded}`;
  if (key.host === "gitlab.com") return `${base}/-/releases/${encoded}`;
  if (key.host === "codeberg.org") return `${base}/releases/tag/${encoded}`;
  return base;
}
