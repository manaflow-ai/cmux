// One SignalRoom per user. Holds every phone and Mac socket of that user with
// the WebSocket hibernation API and relays opaque signaling messages.
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";

export interface PeerInfo {
  id: string;
  kind: "phone" | "host";
  host_id?: string;
  name?: string;
  connected_at: string;
}

const MAX_MESSAGE_BYTES = 64 * 1024;
export const PING = JSON.stringify({ type: "ping" });
export const PONG = JSON.stringify({ type: "pong" });

export class SignalRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  async fetch(request: Request): Promise<Response> {
    const id = request.headers.get("x-peer-id");
    const kind = request.headers.get("x-peer-kind");
    if (!id || (kind !== "phone" && kind !== "host")) return new Response("bad peer", { status: 400 });
    const hostId = request.headers.get("x-host-id") ?? undefined;
    const rawName = request.headers.get("x-peer-name");
    const info: PeerInfo = {
      id,
      kind,
      ...(hostId ? { host_id: hostId } : {}),
      ...(rawName ? { name: decodeURIComponent(rawName) } : {}),
      connected_at: new Date().toISOString(),
    };

    // A reconnect with the same peer id replaces the previous socket.
    for (const old of this.ctx.getWebSockets(id)) {
      try {
        old.close(4000, "replaced");
      } catch {}
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [id, ...(hostId ? [`host:${hostId}`] : [])]);
    server.serializeAttachment(info);
    server.send(JSON.stringify({ type: "welcome", peer: info, peers: this.peers(server) }));
    this.broadcastPresence(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const text = typeof message === "string" ? message : new TextDecoder().decode(message);
    if (text.length > MAX_MESSAGE_BYTES) return this.sendError(ws, "message_too_large");
    let msg: { type?: unknown; to?: unknown; session?: unknown; payload?: unknown };
    try {
      msg = JSON.parse(text);
    } catch {
      return this.sendError(ws, "invalid_json");
    }
    if (msg.type === "ping") return ws.send(PONG);
    if (msg.type !== "signal" || typeof msg.to !== "string")
      return this.sendError(ws, "unknown_type");
    const from = this.info(ws);
    if (!from) return;
    const target = this.live(msg.to).find((t) => t !== ws);
    if (!target) {
      ws.send(JSON.stringify({ type: "error", code: "peer_offline", to: msg.to }));
      return;
    }
    target.send(
      JSON.stringify({ type: "signal", from: from.id, session: msg.session ?? null, payload: msg.payload ?? null }),
    );
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {}
    this.broadcastPresence(null, ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.broadcastPresence(null, ws);
  }

  // ---- RPC used by the Worker

  async onlineHostIds(): Promise<string[]> {
    const ids = new Set<string>();
    for (const ws of this.live()) {
      const info = this.info(ws);
      if (info?.kind === "host" && info.host_id) ids.add(info.host_id);
    }
    return [...ids];
  }

  /** Closes the sockets of one host, or every socket when hostId is null. */
  async disconnect(hostId: string | null): Promise<void> {
    const sockets = hostId ? this.ctx.getWebSockets(`host:${hostId}`) : this.ctx.getWebSockets();
    for (const ws of sockets) {
      try {
        ws.close(4001, "revoked");
      } catch {}
    }
    if (hostId) this.broadcastPresence(null, ...sockets);
  }

  // ---- helpers

  private info(ws: WebSocket): PeerInfo | null {
    return (ws.deserializeAttachment() as PeerInfo | null) ?? null;
  }

  private live(tag?: string): WebSocket[] {
    return this.ctx.getWebSockets(tag).filter((ws) => ws.readyState === WebSocket.OPEN);
  }

  private peers(exclude: WebSocket | null, ...gone: WebSocket[]): PeerInfo[] {
    const out: PeerInfo[] = [];
    for (const ws of this.live()) {
      if (ws === exclude || gone.includes(ws)) continue;
      const info = this.info(ws);
      if (info) out.push(info);
    }
    return out;
  }

  /** Sends each remaining peer the list of the other peers. */
  private broadcastPresence(skip: WebSocket | null, ...gone: WebSocket[]): void {
    for (const ws of this.live()) {
      if (ws === skip || gone.includes(ws)) continue;
      try {
        ws.send(JSON.stringify({ type: "presence", peers: this.peers(ws, ...gone) }));
      } catch {}
    }
  }

  private sendError(ws: WebSocket, code: string): void {
    try {
      ws.send(JSON.stringify({ type: "error", code }));
    } catch {}
  }
}
