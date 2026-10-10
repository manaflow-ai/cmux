import { createHash } from "node:crypto";

import { changelogMedia } from "../../../[locale]/(landing)/docs/changelog/changelog-media";
import { buildHighlights } from "./highlights";

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

const CACHE_CONTROL = "public, max-age=300, s-maxage=300, stale-while-revalidate=86400";
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
