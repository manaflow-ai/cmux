import { CMUX_NEXT_NIGHTLY_FEED_URL } from "./nightly-downloads";

const FEED_TIMEOUT_MS = 5_000;
const MAX_FEED_BYTES = 256 * 1024;

/** Where a feed item's full DMG may live: the R2 origin, or the release the feed falls back to. */
const DMG_ORIGINS = [
  "https://files-next.cmux.com/nightly-next/",
  "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
] as const;

export type NextNightlyDownloadErrorCode = "upstream_unavailable" | "invalid_feed";

/** Why the newest cmux NEXT DMG could not be read from the feed. */
export class NextNightlyDownloadError extends Error {
  constructor(readonly code: NextNightlyDownloadErrorCode) {
    super(code);
    this.name = "NextNightlyDownloadError";
  }
}

export interface NextNightlyDownloadDependencies {
  readonly fetch?: typeof globalThis.fetch;
}

export interface NextNightlyDownloadResolution {
  /** The build number (`sparkle:version`) of the feed's newest item. */
  readonly build: string;
  /** That item's full DMG. */
  readonly url: string;
}

/**
 * Reads the cmux NEXT update feed and returns its newest build's full DMG.
 *
 * The newest item is the highest `sparkle:version`, whatever order the feed
 * lists items in. Its DMG must sit on a published origin and carry that build
 * number in its name, so a malformed or hijacked feed never sends a visitor
 * elsewhere.
 */
export async function resolveNextNightlyDownload(
  dependencies: NextNightlyDownloadDependencies = {},
): Promise<NextNightlyDownloadResolution> {
  const xml = await fetchFeed(dependencies.fetch ?? globalThis.fetch);
  let newest: { build: bigint; text: string; body: string } | undefined;
  for (const match of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const body = match[1] ?? "";
    const version = body.match(/<sparkle:version>(\d{1,20})<\/sparkle:version>/)?.[1];
    if (!version) continue;
    const build = BigInt(version);
    if (!newest || build > newest.build) newest = { build, text: version, body };
  }
  if (!newest) throw new NextNightlyDownloadError("invalid_feed");

  // The full DMG is the item's enclosure outside <sparkle:deltas>.
  const full = newest.body.replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g, "");
  const url = full.match(/<enclosure\b[^>]*\burl="([^"]+)"/)?.[1];
  if (!url || !isPublishedDmg(url, newest.text)) {
    throw new NextNightlyDownloadError("invalid_feed");
  }
  return { build: newest.text, url };
}

function isPublishedDmg(url: string, build: string): boolean {
  return DMG_ORIGINS.some(
    (origin) => url === `${origin}cmux-nightly-next-macos-arm64-${build}.dmg`,
  );
}

async function fetchFeed(fetchImplementation: typeof globalThis.fetch): Promise<string> {
  let response: Response;
  try {
    response = await fetchImplementation(CMUX_NEXT_NIGHTLY_FEED_URL, {
      cache: "no-store",
      headers: { Accept: "application/rss+xml, application/xml, text/xml" },
      signal: AbortSignal.timeout(FEED_TIMEOUT_MS),
    });
  } catch {
    throw new NextNightlyDownloadError("upstream_unavailable");
  }
  if (!response.ok) throw new NextNightlyDownloadError("upstream_unavailable");
  const text = await response.text().catch(() => {
    throw new NextNightlyDownloadError("upstream_unavailable");
  });
  if (text.length > MAX_FEED_BYTES) throw new NextNightlyDownloadError("invalid_feed");
  return text;
}
