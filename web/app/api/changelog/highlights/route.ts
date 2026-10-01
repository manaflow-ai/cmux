import { createHash } from "node:crypto";

import {
  changelogMedia,
  type FeatureHighlight,
  type VersionMedia,
} from "../../../[locale]/(landing)/docs/changelog/changelog-media";

/**
 * GET /api/changelog/highlights
 *
 * The per-version highlights the changelog page shows, as JSON for the macOS
 * app's What's New recap. `changelog-media.ts` stays the one source of truth:
 * the page and the app read the same entries, so a release is written once.
 *
 * Media paths in `changelog-media.ts` are relative to `/public`; they are
 * served here as absolute https URLs on the site origin so the app can load
 * them directly. A feature clip is served as its H.264 mp4 (`video`), which
 * AVPlayer plays; its poster stands in as the feature's still when the entry
 * has no `image`.
 */

const SITE_ORIGIN = "https://cmux.com";
const CACHE_CONTROL = "public, max-age=300, s-maxage=300, stale-while-revalidate=86400";
/**
 * The recap never shows more than a handful of releases, and the entry list
 * grows with every release, so the response is capped rather than unbounded.
 */
export const MAX_RELEASES = 20;

export interface HighlightFeature {
  title: string;
  description: string;
  tryIt?: string;
  image?: string;
  video?: string;
}

export interface HighlightRelease {
  version: string;
  title: string;
  url: string;
  hero?: string;
  features: HighlightFeature[];
}

export interface HighlightsPayload {
  releases: HighlightRelease[];
}

/** Builds the payload from `changelog-media.ts`-shaped entries, newest release first. */
export function buildHighlights(
  media: Record<string, VersionMedia>,
  origin: string = SITE_ORIGIN,
): HighlightsPayload {
  const releases = Object.entries(media)
    .filter(([version]) => /^\d+(\.\d+)*$/.test(version))
    .sort(([a], [b]) => compareDottedVersions(b, a))
    .slice(0, MAX_RELEASES)
    .map(([version, entry]) => toRelease(version, entry, origin));
  return { releases };
}

/** One release, linked to its changelog page. */
function toRelease(version: string, entry: VersionMedia, origin: string): HighlightRelease {
  const release: HighlightRelease = {
    version,
    title: entry.title,
    url: `${origin}/docs/changelog/${version}`,
    features: (entry.features ?? []).map((feature) => toFeature(feature, origin)),
  };
  const hero = absoluteMediaURL(entry.hero, origin);
  if (hero) release.hero = hero;
  return release;
}

/** One feature card with absolute media URLs and a trimmed `tryIt`. */
function toFeature(feature: FeatureHighlight, origin: string): HighlightFeature {
  const output: HighlightFeature = {
    title: feature.title,
    description: feature.description,
  };
  const tryIt = feature.tryIt?.trim();
  if (tryIt) output.tryIt = tryIt;
  const image = absoluteMediaURL(feature.image ?? feature.video?.poster, origin);
  if (image) output.image = image;
  const video = absoluteMediaURL(feature.video?.src, origin);
  if (video) output.video = video;
  return output;
}

/** An https URL as-is, a `/public` path on `origin`, anything else dropped. */
function absoluteMediaURL(path: string | undefined, origin: string): string | undefined {
  const value = path?.trim();
  if (!value) return undefined;
  if (/^https:\/\//.test(value)) return value;
  if (!value.startsWith("/")) return undefined;
  return `${origin}${value}`;
}

/** Dotted-numeric compare; missing components count as zero. */
export function compareDottedVersions(a: string, b: string): number {
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

const PAYLOAD = JSON.stringify(buildHighlights(changelogMedia));
const ETAG = `"${createHash("sha256").update(PAYLOAD).digest("base64url")}"`;

/** Serves the highlights JSON, answering a matching `If-None-Match` with 304. */
export async function GET(request: Request): Promise<Response> {
  const ifNoneMatch = request.headers.get("if-none-match");
  if (ifNoneMatch?.split(",").some((value) => value.trim() === ETAG)) {
    return new Response(null, { status: 304, headers: commonHeaders() });
  }
  return new Response(PAYLOAD, {
    status: 200,
    headers: {
      ...commonHeaders(),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

/** Headers shared by the 200 and 304 responses. */
function commonHeaders(): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    ETag: ETAG,
    "Access-Control-Allow-Origin": "*",
  };
}
