import {
  type FeatureHighlight,
  type VersionMedia,
} from "../../../[locale]/(landing)/docs/changelog/changelog-media";

const SITE_ORIGIN = "https://cmux.com";

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
