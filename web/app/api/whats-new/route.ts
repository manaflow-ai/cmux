import { createHash } from "node:crypto";

import {
  whatsNewList,
  type WhatsNewAnnouncement,
  type WhatsNewAnnouncementFeature,
  type WhatsNewList,
} from "../../../data/whats-new";

const CACHE_CONTROL = "public, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, OPTIONS";
const ALLOW_HEADERS = "If-None-Match, Content-Type";
/** In-app What's New webpages may load cmux-owned hosts only. */
const ALLOWED_WEB_URL_HOSTS = new Set(["cmux.com", "www.cmux.com"]);
const VERSION_PATTERN = /^\d+(\.\d+)*$/;
const PAYLOAD = JSON.stringify(validateList(whatsNewList));
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

/**
 * Validates the reviewed list before it can be served: version bounds are
 * required and well-formed, ids are unique, every announcement resolves to
 * at least one content source, and web URLs stay on cmux-owned https hosts.
 */
export function validateList(input: WhatsNewList): WhatsNewList {
  const seenEntryIDs = new Set<string>();
  for (const id of input.visibleEntryIds) {
    const trimmed = nonemptyString(id, "visibleEntryIds[]");
    if (seenEntryIDs.has(trimmed)) {
      throw new Error(`visibleEntryIds contains duplicate id ${trimmed}`);
    }
    seenEntryIDs.add(trimmed);
  }

  const seenAnnouncementIDs = new Set<string>();
  for (const [index, announcement] of input.announcements.entries()) {
    const path = `announcements[${index}]`;
    validateAnnouncement(announcement, path);
    if (seenAnnouncementIDs.has(announcement.id)) {
      throw new Error(`announcements contains duplicate id ${announcement.id}`);
    }
    seenAnnouncementIDs.add(announcement.id);
  }
  return input;
}

function validateAnnouncement(announcement: WhatsNewAnnouncement, path: string): void {
  nonemptyString(announcement.id, `${path}.id`);
  version(announcement.minVersion, `${path}.minVersion`);
  version(announcement.maxVersion, `${path}.maxVersion`);
  if (announcement.releaseLabel !== undefined) {
    nonemptyString(announcement.releaseLabel, `${path}.releaseLabel`);
  }

  const hasNative = announcement.nativeEntryId !== undefined;
  const hasWeb = announcement.webUrl !== undefined;
  const hasFeatures = (announcement.features?.length ?? 0) > 0;
  if (hasNative) nonemptyString(announcement.nativeEntryId, `${path}.nativeEntryId`);
  if (hasWeb) webURL(announcement.webUrl, `${path}.webUrl`);
  for (const [index, feature] of (announcement.features ?? []).entries()) {
    validateFeature(feature, `${path}.features[${index}]`);
  }
  if (!hasNative && !hasWeb && !hasFeatures) {
    throw new Error(
      `${path} needs a nativeEntryId, a webUrl, or feature rows to render`,
    );
  }
  // Only a native-only announcement can borrow its title from the binary
  // catalog. Fallback content (webUrl or features) renders on binaries that
  // do not carry the native entry, and those binaries have no title source,
  // so a missing title would silently drop the announcement there.
  if (announcement.title === undefined && (!hasNative || hasWeb || hasFeatures)) {
    throw new Error(
      `${path}.title is required unless the announcement is native-only`,
    );
  }
  if (announcement.title !== undefined) {
    nonemptyString(announcement.title, `${path}.title`);
  }
}

function validateFeature(feature: WhatsNewAnnouncementFeature, path: string): void {
  nonemptyString(feature.title, `${path}.title`);
  nonemptyString(feature.detail, `${path}.detail`);
  if (feature.symbol !== undefined) nonemptyString(feature.symbol, `${path}.symbol`);
}

function version(input: string | undefined, path: string): void {
  const value = nonemptyString(input, path);
  if (!VERSION_PATTERN.test(value)) {
    throw new Error(`${path} must be a dotted numeric version, got ${value}`);
  }
}

function webURL(input: string | undefined, path: string): void {
  const value = nonemptyString(input, path);
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${path} must be an absolute URL`);
  }
  // Dev servers preview entries against their own localhost web app. The
  // allowance is deliberately environment-independent so validation cannot
  // pass in development and then throw during production module
  // initialization; production devices never render loopback URLs because
  // the client's own allowlist restricts http to loopback dev hosts.
  const isLoopbackDev =
    url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  if (isLoopbackDev) return;
  if (url.protocol !== "https:") {
    throw new Error(`${path} must use https`);
  }
  if (!ALLOWED_WEB_URL_HOSTS.has(url.hostname.toLowerCase())) {
    throw new Error(`${path} must be on a cmux-owned host, got ${url.hostname}`);
  }
}

function nonemptyString(input: string | undefined, path: string): string {
  if (typeof input !== "string" || input.trim().length === 0) {
    throw new Error(`${path} must be a nonempty string`);
  }
  // The served payload is the input verbatim, so committed values must
  // already be normalized: a stray space in an id would otherwise pass
  // validation here and then silently fail exact-match lookups on device.
  if (input !== input.trim()) {
    throw new Error(`${path} must not have leading or trailing whitespace`);
  }
  return input;
}

export async function GET(request: Request): Promise<Response> {
  if (matchesETag(request.headers.get("if-none-match"))) {
    return new Response(null, {
      status: 304,
      headers: commonHeaders(),
    });
  }

  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function OPTIONS(): Response {
  return new Response(null, {
    status: 204,
    headers: commonHeaders(),
  });
}

function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
  };
}

function matchesETag(header: string | null): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim();
    return candidate === ETAG || candidate === "*";
  });
}
