// Public release-push routes (no auth, no /v1 Stack verification): they carry
// only what the allowlisted public appcasts already show.
//   GET  /releases/v1/socket?feed=<id>   WebSocket: the current release frame, then one per new build
//   POST /releases/v1/poke?feed=<id>     re-read that feed's appcast (coalesced), 202 {"build":N}
//   GET  /releases/v1/latest?feed=<id>   the current release frame as JSON
import { RELEASE_FEEDS, parseReleaseFeedId, type ReleaseFeedId } from "./releaseFeed";

export const RELEASE_ROUTE_PREFIX = "/releases/v1/";

/** The slice of DurableObjectNamespace<ReleaseFeed> these routes use, kept
 * structural so bun tests can pass a fake. */
export interface ReleaseFeedNamespace {
  idFromName(name: string): unknown;
  get(id: never): { fetch(request: Request): Promise<Response> };
}

export interface ReleaseFeedEnv {
  RELEASE_FEED: ReleaseFeedNamespace;
}

function feedStub(env: ReleaseFeedEnv, feed: ReleaseFeedId) {
  return env.RELEASE_FEED.get(env.RELEASE_FEED.idFromName(feed) as never);
}

const ROUTES: Record<string, { method: string; websocket?: true }> = {
  socket: { method: "GET", websocket: true },
  poke: { method: "POST" },
  latest: { method: "GET" },
};

export async function releaseFeedRoute(request: Request, env: ReleaseFeedEnv): Promise<Response> {
  const url = new URL(request.url);
  const name = url.pathname.slice(RELEASE_ROUTE_PREFIX.length);
  const route = Object.hasOwn(ROUTES, name) ? ROUTES[name] : undefined;
  if (!route) return Response.json({ error: "not_found" }, { status: 404 });
  if (request.method !== route.method) return Response.json({ error: "method_not_allowed" }, { status: 405 });
  const feed = parseReleaseFeedId(url.searchParams.get("feed"));
  if (!feed) return Response.json({ error: "unknown_feed" }, { status: 404 });
  if (route.websocket && request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return Response.json({ error: "websocket_required" }, { status: 400 });
  }
  // Rebuild the request: only the validated feed id reaches the object, never
  // a caller's headers or body.
  const headers = new Headers({ "x-release-feed": feed });
  if (route.websocket) headers.set("upgrade", "websocket");
  return feedStub(env, feed).fetch(new Request(`https://release-feed/${name}`, { method: route.method, headers }));
}

/** The minute cron: poke every feed, so a missed publisher poke heals within a
 * minute. Each poke is one bounded appcast read; a failed one waits for the next tick. */
export async function pokeAllReleaseFeeds(env: ReleaseFeedEnv): Promise<void> {
  await Promise.allSettled((Object.keys(RELEASE_FEEDS) as ReleaseFeedId[]).map(async (feed) => {
    const response = await feedStub(env, feed).fetch(new Request("https://release-feed/poke", {
      method: "POST",
      headers: { "x-release-feed": feed },
    }));
    await response.body?.cancel();
  }));
}
