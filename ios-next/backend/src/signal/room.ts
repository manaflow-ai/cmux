import { DurableObject } from "cloudflare:workers";
import type { AppEnv } from "../env";
import { repoFromEnv } from "../repo";
import { addressOf, directionError, errorFrame, parseRelayFrame, targetRole, type PeerInfo } from "./frames";

export const HEADER_ROLE = "x-cmux-role";
export const HEADER_USER = "x-cmux-user-id";
export const HEADER_HOST = "x-cmux-host-id";
export const HEADER_HOSTS = "x-cmux-hosts";
export const HEADER_PEER = "x-cmux-peer-id";

/** Throttle for hosts.last_seen_at writes while a host is connected. */
export const LAST_SEEN_INTERVAL_MS = 60 * 1000;

const tagPeer = (peerId: string) => `peer:${peerId}`;
const tagHost = (hostId: string) => `host:${hostId}`;
const tagRole = (role: string) => `role:${role}`;

/**
 * One room per user. Every phone and host socket of that user lives here
 * (WebSocket Hibernation API), and the room relays signaling between them.
 */
export class SignalRoom extends DurableObject<AppEnv> {
  private lastSeenWrites = new Map<string, number>();

  constructor(ctx: DurableObjectState, env: AppEnv) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/connect":
        return this.acceptPeer(request);
      case "/internal/online":
        return Response.json({ hostIds: this.onlineHostIds() });
      case "/internal/host-removed": {
        const hostId = url.searchParams.get("hostId") ?? "";
        for (const ws of this.ctx.getWebSockets(tagHost(hostId))) safeClose(ws, 4003, "host removed");
        this.broadcastToPhones({ type: "presence", hostId, online: false, removed: true });
        return Response.json({});
      }
      case "/internal/close-all":
        for (const ws of this.ctx.getWebSockets()) safeClose(ws, 4004, "account deleted");
        return Response.json({});
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private acceptPeer(request: Request): Response {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 });
    const role = request.headers.get(HEADER_ROLE);
    const userId = request.headers.get(HEADER_USER);
    const peerId = request.headers.get(HEADER_PEER);
    const hostId = request.headers.get(HEADER_HOST) ?? undefined;
    if ((role !== "phone" && role !== "host") || !userId || !peerId || (role === "host" && !hostId)) {
      return new Response("bad connect", { status: 400 });
    }
    let knownHosts: string[] = [];
    try {
      knownHosts = JSON.parse(request.headers.get(HEADER_HOSTS) ?? "[]");
    } catch {
      knownHosts = [];
    }

    const peer: PeerInfo = role === "host" ? { peerId, role, hostId, userId } : { peerId, role, userId };
    const replaced = role === "host" ? this.ctx.getWebSockets(tagHost(hostId!)) : [];

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    const tags = [tagPeer(peerId), tagRole(role)];
    if (hostId) tags.push(tagHost(hostId));
    this.ctx.acceptWebSocket(server, tags);
    server.serializeAttachment(peer);

    // A host reconnecting replaces its previous socket.
    for (const old of replaced) safeClose(old, 4001, "replaced by a newer connection");

    const online = new Set(this.onlineHostIds());
    const hosts = [...new Set([...knownHosts, ...online])].map((id) => ({ hostId: id, online: online.has(id) }));
    server.send(JSON.stringify({ type: "welcome", peerId, hosts }));

    if (role === "host") {
      this.broadcastToPhones({ type: "presence", hostId, online: true });
      this.touchHost(hostId!, true);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const sender = ws.deserializeAttachment() as PeerInfo | null;
    if (!sender) return;
    const frame = parseRelayFrame(message);
    if (frame.type === "error") {
      send(ws, frame);
      return;
    }
    const direction = directionError(sender, frame);
    if (direction) {
      send(ws, direction);
      return;
    }
    const role = targetRole(sender);
    const targets = (role === "host" ? this.ctx.getWebSockets(tagHost(frame.to)) : this.ctx.getWebSockets(tagPeer(frame.to))).filter(
      (t) => (t.deserializeAttachment() as PeerInfo | null)?.role === role,
    );
    if (targets.length === 0) {
      send(ws, errorFrame(role === "host" ? "host_offline" : "peer_offline", `${frame.to} is not connected`, frame.sessionId));
    } else {
      const out = JSON.stringify({ ...frame, from: addressOf(sender) });
      for (const t of targets) send(t, out);
    }
    if (sender.role === "host" && sender.hostId) this.touchHost(sender.hostId, false);
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    safeClose(ws, code === 1005 || code === 1006 ? 1000 : code, reason);
    this.onSocketGone(ws);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.onSocketGone(ws);
  }

  private onSocketGone(ws: WebSocket) {
    const peer = ws.deserializeAttachment() as PeerInfo | null;
    if (peer?.role !== "host" || !peer.hostId) return;
    const stillOnline = this.ctx.getWebSockets(tagHost(peer.hostId)).some((w) => w !== ws && w.readyState === WebSocket.OPEN);
    if (stillOnline) return;
    this.broadcastToPhones({ type: "presence", hostId: peer.hostId, online: false });
    this.touchHost(peer.hostId, true);
  }

  private onlineHostIds(): string[] {
    const ids = new Set<string>();
    for (const ws of this.ctx.getWebSockets(tagRole("host"))) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      const peer = ws.deserializeAttachment() as PeerInfo | null;
      if (peer?.hostId) ids.add(peer.hostId);
    }
    return [...ids];
  }

  private broadcastToPhones(frame: unknown) {
    const out = JSON.stringify(frame);
    for (const ws of this.ctx.getWebSockets(tagRole("phone"))) send(ws, out);
  }

  /** Updates hosts.last_seen_at, at most once per LAST_SEEN_INTERVAL_MS unless forced. */
  private touchHost(hostId: string, force: boolean) {
    const now = Date.now();
    const last = this.lastSeenWrites.get(hostId) ?? 0;
    if (!force && now - last < LAST_SEEN_INTERVAL_MS) return;
    this.lastSeenWrites.set(hostId, now);
    const repo = repoFromEnv(this.env);
    if (!repo) return;
    this.ctx.waitUntil(
      repo.touchHost(hostId, now).catch((err: unknown) => console.error("touchHost failed", err instanceof Error ? err.message : err)),
    );
  }
}

function send(ws: WebSocket, frame: unknown) {
  try {
    ws.send(typeof frame === "string" ? frame : JSON.stringify(frame));
  } catch {
    // Socket already closing.
  }
}

function safeClose(ws: WebSocket, code: number, reason: string) {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}
