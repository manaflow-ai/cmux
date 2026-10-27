import { DurableObject } from "cloudflare:workers";
import {
  MAX_RELEASE_SOCKETS,
  ReleaseFeedCore,
  fetchAppcast,
  parseReleaseFeedId,
  type ReleaseFeedId,
  type ReleaseState,
} from "./releaseFeed";

const STATE_KEY = "release";

/** One allowlisted update feed (named by its feed id): the newest build it
 * serves, pushed to every hibernating socket the moment a read sees it rise. */
export class ReleaseFeed extends DurableObject {
  private core: ReleaseFeedCore | null = null;

  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx, env);
    // Answered by the runtime without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** `/socket`, `/poke` and `/latest`, forwarded by releaseFeedRoute.ts with
   * the validated feed id in `x-release-feed`. */
  async fetch(request: Request): Promise<Response> {
    const feed = parseReleaseFeedId(request.headers.get("x-release-feed"));
    if (!feed) return Response.json({ error: "unknown_feed" }, { status: 404 });
    // The alarm handler has no request to name the feed, so the object keeps it.
    if (!this.core) await this.ctx.storage.put("feed", feed);
    const core = this.feedCore(feed);
    const path = new URL(request.url).pathname;
    if (path.endsWith("/poke")) return Response.json(await core.poke(), { status: 202 });
    if (path.endsWith("/latest")) {
      const frame = await core.current();
      return frame
        ? new Response(frame, { headers: { "content-type": "application/json", "cache-control": "no-store" } })
        : Response.json({ error: "feed_unavailable" }, { status: 503, headers: { "Retry-After": "10" } });
    }
    if (this.ctx.getWebSockets().length >= MAX_RELEASE_SOCKETS) {
      return new Response(null, { status: 429, headers: { "Retry-After": "60" } });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    const frame = await core.current();
    if (frame) {
      try { pair[1].send(frame); } catch { /* closed already; nothing to deliver */ }
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** The deferred read a coalesced poke armed. */
  async alarm(): Promise<void> {
    const feed = parseReleaseFeedId(await this.ctx.storage.get<string>("feed") ?? null);
    if (feed) await this.feedCore(feed).alarm();
  }

  /** The server sends only release frames; anything but the auto-answered
   * "ping" is ignored. */
  async webSocketMessage(): Promise<void> {}

  async webSocketClose(): Promise<void> {}

  async webSocketError(ws: WebSocket): Promise<void> {
    try { ws.close(1011, "Connection ended"); } catch { /* already closed */ }
  }

  private feedCore(feed: ReleaseFeedId): ReleaseFeedCore {
    if (this.core) return this.core;
    this.core = new ReleaseFeedCore(feed, {
      now: () => Date.now(),
      fetchAppcast: (url) => fetchAppcast(url),
      load: async () => (await this.ctx.storage.get<ReleaseState>(STATE_KEY)) ?? null,
      save: (state) => this.ctx.storage.put(STATE_KEY, state),
      broadcast: (frame) => {
        for (const ws of this.ctx.getWebSockets()) {
          try { ws.send(frame); } catch { /* a dead socket closes on its own */ }
        }
      },
      getAlarm: () => this.ctx.storage.getAlarm(),
      setAlarm: (at) => this.ctx.storage.setAlarm(at),
    });
    return this.core;
  }
}
