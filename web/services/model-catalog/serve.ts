// HTTP for `GET /api/models/v1`: one public JSON body, a strong content-hash
// ETag, 304 on a matching If-None-Match, and shared-cache headers. No auth,
// no cookies, no user data.

import type { BuiltCatalog, CatalogStore, Defer } from "./store";

/** Clients check every 6 h; the CDN keeps a copy for 1 h and may serve it stale for a day. */
export const CACHE_CONTROL = "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400";
const ALLOW_METHODS = "GET, HEAD, OPTIONS";
const ALLOW_HEADERS = "If-None-Match";

function commonHeaders(built: BuiltCatalog | undefined): Record<string, string> {
  return {
    "Cache-Control": CACHE_CONTROL,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
    "Access-Control-Expose-Headers": "ETag, X-Cmux-Catalog-Source",
    "X-Content-Type-Options": "nosniff",
    ...(built
      ? { ETag: built.etag, "X-Cmux-Catalog-Source": built.source, "X-Cmux-Catalog-Fetched-At": built.fetchedAt }
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

export async function serveModelCatalog(request: Request, store: CatalogStore, defer: Defer): Promise<Response> {
  // Read the request first: it marks the route dynamic, so it is never prerendered at build time.
  const ifNoneMatch = request.headers.get("if-none-match");
  const built = await store.current(defer);
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
