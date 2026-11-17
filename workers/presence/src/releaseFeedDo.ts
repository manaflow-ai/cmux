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
const READ_AT_KEY = "readAt";

/** One allowlisted update feed (named by its feed id): the newest build it
 * serves, pushed to every hibernating socket the moment a read sees it rise. */
export class ReleaseFeed extends DurableObject<unknown> {
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
    if (path.endsWith("/poke")) {
      const { build } = await core.poke();
      // 202 always names a build; a feed never read successfully is a 503.
      return build === null
        ? Response.json({ error: "feed_unavailable" }, { status: 503, headers: { "Retry-After": "10" } })
        : Response.json({ build }, { status: 202 });
    }
    if (path.endsWith("/latest")) {
      const frame = await core.current();
      return frame
        ? new Response(frame, { headers: { "content-type": "application/json", "cache-control": "no-store" } })
        : Response.json({ error: "feed_unavailable" }, { status: 503, headers: { "Retry-After": "10" } });
    }
    // Settle the state BEFORE the socket joins: a first read inside current()
    // broadcasts to the sockets already here, never to this one, so the new
    // socket gets exactly one initial frame.
    await core.current();
    // The cap is checked with no await between it and acceptWebSocket, so
    // concurrent handshakes cannot all pass on one stale count.
    if (this.ctx.getWebSockets().length >= MAX_RELEASE_SOCKETS) {
      return new Response(null, { status: 429, headers: { "Retry-After": "60" } });
    }
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    // Read with no await since accept: any broadcast from here on reaches this
    // socket too, and any earlier one is already in latestFrame.
    const frame = core.latestFrame;
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
      loadReadAt: async () => (await this.ctx.storage.get<number>(READ_AT_KEY)) ?? 0,
      saveReadAt: (at) => this.ctx.storage.put(READ_AT_KEY, at),
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
