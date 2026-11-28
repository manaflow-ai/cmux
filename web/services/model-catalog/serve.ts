// HTTP for `GET /api/models/v1`: one public JSON body, a strong content-hash
// ETag, 304 on a matching If-None-Match, and shared-cache headers. No auth,
// no cookies, no user data.

import type { BuiltCatalog, CatalogStore } from "./store";

/** Clients check every 6 h; the CDN keeps a live copy for 1 h and may serve it stale for a day. */
export const LIVE_CACHE_CONTROL = "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400";
/** The snapshot is cached briefly, so the CDN asks again soon after a live refresh. */
export const SNAPSHOT_CACHE_CONTROL = "public, max-age=60, s-maxage=300, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, HEAD, OPTIONS";
const ALLOW_HEADERS = "If-None-Match";

function commonHeaders(built: BuiltCatalog | undefined): Record<string, string> {
  return {
    "Cache-Control": built?.catalog.source === "live" ? LIVE_CACHE_CONTROL : SNAPSHOT_CACHE_CONTROL,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
    "Access-Control-Expose-Headers": "ETag, X-Cmux-Catalog-Source, X-Cmux-Catalog-Version",
    "X-Content-Type-Options": "nosniff",
    ...(built
      ? {
          ETag: built.etag,
          "X-Cmux-Catalog-Source": built.catalog.source,
          ...(built.version === null ? {} : { "X-Cmux-Catalog-Version": String(built.version) }),
        }
      : {}),
  };
}

export function matchesETag(header: string | null, etag: string): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim().replace(/^W\//, "");
    return candidate === etag || candidate === "*";
  });
}

export async function serveModelCatalog(request: Request, store: Pick<CatalogStore, "current">): Promise<Response> {
  // Read the request first: it marks the route dynamic, so it is never prerendered at build time.
  const ifNoneMatch = request.headers.get("if-none-match");
  const built = await store.current();
  if (matchesETag(ifNoneMatch, built.etag)) {
    return new Response(null, { status: 304, headers: commonHeaders(built) });
  }
  return new Response(request.method === "HEAD" ? null : built.body, {
    status: 200,
    headers: {
      ...commonHeaders(built),
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": String(Buffer.byteLength(built.body)),
    },
  });
}

export function catalogPreflight(): Response {
  return new Response(null, { status: 204, headers: commonHeaders(undefined) });
}
