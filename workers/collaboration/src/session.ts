import { DurableObject } from "cloudflare:workers";
import { parsePeer } from "./protocol";
import { CollaborationRelaySessionState } from "./session-state";
import { createSessionMetadata, readSessionMetadata, type SessionMetadata } from "./session-metadata";

const HEARTBEAT_TIMEOUT_MS = 30_000;

export class CollaborationSessionObject extends DurableObject {
  private metadata: SessionMetadata | null = null;
  private state = new CollaborationRelaySessionState();

  async create(sessionCode: string): Promise<SessionMetadata> {
    if (this.metadata !== null) return this.metadata;
    this.metadata = await createSessionMetadata(this.ctx.storage, sessionCode);
    return this.metadata;
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/connect")) {
      return this.handleConnect(request);
    }
    return new Response("not found", { status: 404 });
  }

  private async handleConnect(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const metadata = await this.loadMetadata();
    if (metadata === null) {
      return new Response(JSON.stringify({ error: "session_not_found" }), { status: 404 });
    }
    const url = new URL(request.url);
    if (url.searchParams.get("token") !== metadata.token) {
      return new Response(JSON.stringify({ error: "invalid_token" }), { status: 403 });
    }
    const peer = parsePeer({
      peerID: url.searchParams.get("peerID"),
      displayName: url.searchParams.get("displayName"),
      color: url.searchParams.get("color"),
    });
    if (peer === null) {
      return new Response(JSON.stringify({ error: "invalid_peer" }), { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();
    this.state.addPeer(metadata.sessionID, peer, server, Date.now());
    server.addEventListener("message", (event) => this.state.handleMessage(peer.peerID, event.data, Date.now()));
    server.addEventListener("close", () => this.state.dropPeer(peer.peerID, "disconnect"));
    server.addEventListener("error", () => this.state.dropPeer(peer.peerID, "disconnect"));
    await this.ensureAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  override async alarm(): Promise<void> {
    this.state.expire(Date.now(), HEARTBEAT_TIMEOUT_MS);
    if (this.state.peerCount > 0) await this.ensureAlarm();
  }

  private async ensureAlarm(): Promise<void> {
    await this.ctx.storage.setAlarm(Date.now() + HEARTBEAT_TIMEOUT_MS);
  }

  private async loadMetadata(): Promise<SessionMetadata | null> {
    if (this.metadata !== null) return this.metadata;
    this.metadata = await readSessionMetadata(this.ctx.storage);
    return this.metadata;
  }
}
