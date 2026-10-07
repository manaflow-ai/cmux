import { createHash } from "node:crypto";

import snapshot from "../../data/model-catalog-snapshot.json";
import { projectCatalog } from "./project";
import type { ModelCatalog } from "./types";

// GET /api/models/catalog: the public model feed projected through the cmux overrides. The CDN
// caches the answer (1 h fresh, a day stale-while-revalidate); each function instance also keeps
// its last projection for an hour so a cold CDN does not refetch the 5 MB feed per request. When
// the feed fails, the last good projection is served, else the bundled snapshot with a short TTL.

export const MODEL_FEED_URL = "https://models.dev/api.json";
const FRESH_MS = 60 * 60 * 1000;
const FEED_TIMEOUT_MS = 15_000;
/** After a failed refresh, the stale projection is served this long before the next try. */
const RETRY_MS = 5 * 60 * 1000;
const LIVE_CACHE = "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400";
const FALLBACK_CACHE = "public, max-age=60, s-maxage=300, stale-while-revalidate=86400";

export interface CatalogRouteDeps {
  fetchFeed: () => Promise<Response>;
  now: () => Date;
}

type Prepared = { body: string; etag: string; source: ModelCatalog["source"]; at: number };

export function defaultFetchFeed(): Promise<Response> {
  return fetch(MODEL_FEED_URL, {
    cache: "no-store",
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(FEED_TIMEOUT_MS),
  });
}

export function createCatalogRoute(deps: CatalogRouteDeps): {
  GET: (request: Request) => Promise<Response>;
  OPTIONS: () => Response;
} {
  let live: Prepared | undefined;
  let fallback: Prepared | undefined;

  async function current(): Promise<Prepared> {
    const now = deps.now();
    if (live && now.getTime() - live.at < FRESH_MS) return live;
    if (!live && fallback && now.getTime() - fallback.at < RETRY_MS) return fallback;
    try {
      live = prepare(await loadFeed(deps, now), now.getTime());
      return live;
    } catch (error) {
      console.warn("model catalog feed refresh failed", error instanceof Error ? error.message : error);
      if (live) {
        live = { ...live, at: now.getTime() - FRESH_MS + RETRY_MS };
        return live;
      }
      fallback = { ...(fallback ?? prepare(snapshot as ModelCatalog, now.getTime())), at: now.getTime() };
      return fallback;
    }
  }

  return {
    async GET(request) {
      const prepared = await current();
      const headers = { ...commonHeaders(prepared), "X-Cmux-Catalog-Source": prepared.source };
      if (matchesETag(request.headers.get("if-none-match"), prepared.etag)) {
        return new Response(null, { status: 304, headers });
      }
      return new Response(prepared.body, {
        status: 200,
        headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
      });
    },
    OPTIONS() {
      return new Response(null, { status: 204, headers: corsHeaders() });
    },
  };
}

async function loadFeed(deps: CatalogRouteDeps, now: Date): Promise<ModelCatalog> {
  const response = await deps.fetchFeed();
  if (!response.ok) throw new Error(`model feed answered ${response.status}`);
  return projectCatalog(await response.json(), now);
}

function prepare(catalog: ModelCatalog, at: number): Prepared {
  const body = JSON.stringify(catalog);
  const etag = `"${createHash("sha256").update(body).digest("base64url")}"`;
  return { body, etag, source: catalog.source, at };
}

function commonHeaders(prepared: Prepared): Record<string, string> {
  return {
    ...corsHeaders(),
    "Cache-Control": prepared.source === "live" ? LIVE_CACHE : FALLBACK_CACHE,
    ETag: prepared.etag,
  };
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "If-None-Match, Content-Type",
    "Access-Control-Expose-Headers": "ETag, X-Cmux-Catalog-Source",
  };
}

function matchesETag(header: string | null, etag: string): boolean {
  if (!header) return false;
  return header.split(",").some((value) => {
    const candidate = value.trim().replace(/^W\//, "");
    return candidate === etag || candidate === "*";
  });
}
