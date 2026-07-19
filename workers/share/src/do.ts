// ShareSession Durable Object: one instance per share code.
//
// Thin wiring only — all protocol decisions live in the pure core
// (src/session.ts). This class owns WebSockets (hibernation API), storage,
// and the alarm, and executes the core's effects. Authorization happened in
// the worker (src/index.ts): by the time a request reaches this object, the
// share token was verified and the caller's identity arrives in x-share-*
// headers. The DO id is derived from the verified code claim, so a token for
// one session can never reach another session's object.

import { DurableObject } from "cloudflare:workers";

import type { GuestMessage, HostMessage } from "./protocol";
import { decodeBinaryHeader } from "./protocol";
import type { Effect, PersistedSession } from "./session";
import { ShareSessionCore } from "./session";

const SESSION_KEY = "session";

/** Serialized into each WebSocket so identity survives hibernation. */
interface Attachment {
  connId: string;
  user: string;
  email: string;
  host: boolean;
}

export interface ShareWorkerEnv {
  SHARE_SESSION: DurableObjectNamespace<ShareSession>;
  /** SPKI PEM for the web API's Ed25519 share-token signing key. */
  SHARE_JWT_PUBLIC_KEY?: string;
}

export class ShareSession extends DurableObject<ShareWorkerEnv> {
  private core: ShareSessionCore | null = null;
  private sockets = new Map<string, WebSocket>();
  private restored = false;

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const user = request.headers.get("x-share-user");
    const email = request.headers.get("x-share-email") ?? "";
    const isHost = request.headers.get("x-share-host") === "1";
    const code = request.headers.get("x-share-code");
    if (!user || !code) return new Response("bad gateway headers", { status: 400 });

    let core = await this.ensureCore();
    if (!core) {
      if (!isHost) return new Response("no such session", { status: 404 });
      const persisted = ShareSessionCore.create(code, { user, email }, Date.now());
      await this.ctx.storage.put(SESSION_KEY, persisted);
      core = new ShareSessionCore(persisted);
      this.core = core;
    } else if (isHost && core.persisted.host.user !== user) {
      // A host-claim token for a code that already belongs to someone else.
      // Codes are minted server-side with ~125 bits of entropy, so this is
      // token misuse, not a collision.
      return new Response("not the session host", { status: 403 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment: Attachment = {
      connId: crypto.randomUUID(),
      user,
      email,
      host: isHost,
    };
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(attachment);
    this.sockets.set(attachment.connId, server);
    this.apply(
      core.connect(attachment.connId, { user, email, hostToken: isHost }, Date.now()),
    );
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const core = await this.ensureCore();
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!core || !attachment) {
      ws.close(1011, "session unavailable");
      return;
    }
    const isHost = attachment.host && core.persisted.host.user === attachment.user;
    if (typeof message !== "string") {
      if (!isHost) return; // guests never send binary
      const bytes = new Uint8Array(message);
      const header = decodeBinaryHeader(bytes);
      if (!header) return;
      this.apply(core.routeBinary(attachment.connId, header.ws, header.pane, bytes));
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(message);
    } catch {
      return;
    }
    if (typeof parsed !== "object" || parsed === null || typeof (parsed as { t?: unknown }).t !== "string") {
      return;
    }
    this.apply(
      isHost
        ? core.handleHost(attachment.connId, parsed as HostMessage)
        : core.handleGuest(attachment.connId, parsed as GuestMessage),
    );
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const core = await this.ensureCore();
    const attachment = ws.deserializeAttachment() as Attachment | null;
    if (!core || !attachment) return;
    this.sockets.delete(attachment.connId);
    this.apply(core.disconnect(attachment.connId, Date.now()));
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  override async alarm(): Promise<void> {
    const core = await this.ensureCore();
    if (!core) return;
    this.apply(core.alarm(Date.now()));
  }

  /**
   * Load the core from storage, re-registering any sockets that survived
   * hibernation/eviction. Clients are asked to `resync` volatile state.
   */
  private async ensureCore(): Promise<ShareSessionCore | null> {
    if (this.core && this.restored) return this.core;
    if (!this.core) {
      const persisted = await this.ctx.storage.get<PersistedSession>(SESSION_KEY);
      if (!persisted) return null;
      this.core = new ShareSessionCore(persisted);
    }
    if (!this.restored) {
      this.restored = true;
      const survivors: Array<{ id: string; user: string; email: string; hostToken: boolean }> =
        [];
      for (const ws of this.ctx.getWebSockets()) {
        const attachment = ws.deserializeAttachment() as Attachment | null;
        if (!attachment) {
          ws.close(1011, "lost attachment");
          continue;
        }
        // Sockets accepted in this instance's lifetime are already registered.
        if (this.sockets.has(attachment.connId)) continue;
        this.sockets.set(attachment.connId, ws);
        survivors.push({
          id: attachment.connId,
          user: attachment.user,
          email: attachment.email,
          hostToken: attachment.host,
        });
      }
      if (survivors.length > 0) {
        this.apply(this.core.restore(survivors, Date.now()));
      }
    }
    return this.core;
  }

  private apply(effects: Effect[]): void {
    const core = this.core;
    for (const effect of effects) {
      switch (effect.kind) {
        case "send": {
          const ws = this.sockets.get(effect.to);
          try {
            ws?.send(JSON.stringify(effect.msg));
          } catch {
            // Socket already gone; close/disconnect bookkeeping follows via
            // webSocketClose.
          }
          break;
        }
        case "sendBinary": {
          const ws = this.sockets.get(effect.to);
          try {
            ws?.send(effect.data);
          } catch {
            // As above.
          }
          break;
        }
        case "close": {
          const ws = this.sockets.get(effect.to);
          this.sockets.delete(effect.to);
          try {
            ws?.close(effect.code, effect.reason);
          } catch {
            // Already closed.
          }
          break;
        }
        case "setAlarm":
          void this.ctx.storage.setAlarm(effect.at);
          break;
        case "clearAlarm":
          void this.ctx.storage.deleteAlarm();
          break;
        case "persist":
          if (core) void this.ctx.storage.put(SESSION_KEY, core.persisted);
          break;
      }
    }
  }
}
