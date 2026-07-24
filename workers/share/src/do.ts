// SPDX-License-Identifier: GPL-3.0-or-later
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

import {
  decodeClientJson,
  isIdentityEmail,
  isProtocolId,
  MAX_JSON_FRAME_BYTES,
  parseAckMessage,
  parseGuestMessage,
  parseHostMessage,
  utf8ByteLength,
} from "./protocol";
import {
  createSocketAttachment,
  DELIVERY_FAILURE_CLOSE_CODE,
  DELIVERY_FAILURE_CLOSE_REASON,
  dispatchEffects,
  MAX_SOCKET_BUFFERED_BYTES,
  parseSocketAttachment,
  releaseDeliveryCredit,
  serializeSocketAttachment,
  type ShareSocketAttachment,
} from "./outbound";
import { ApplicationIngressLimiter, validateBinaryIngress } from "./ingress";
import type { Effect } from "./session";
import {
  RATE_LIMIT_CLOSE_CODE,
  RATE_LIMIT_CLOSE_REASON,
  restorePersistedSession,
  ShareSessionCore,
} from "./session";

export { MAX_SOCKET_BUFFERED_BYTES };

const SESSION_KEY = "session";

export interface ShareWorkerEnv {
  SHARE_SESSION: DurableObjectNamespace<ShareSession>;
  /** SPKI PEM for the web API's Ed25519 share-token signing key. */
  SHARE_JWT_PUBLIC_KEY?: string;
}

export class ShareSession extends DurableObject<ShareWorkerEnv> {
  private core: ShareSessionCore | null = null;
  private sockets = new Map<string, WebSocket>();
  private attachments = new Map<string, ShareSocketAttachment>();
  private readonly ingress = new ApplicationIngressLimiter();
  private pendingRestoreEffects: Effect[] = [];
  private restored = false;

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const user = request.headers.get("x-share-user");
    const email = request.headers.get("x-share-email") ?? "";
    const isHost = request.headers.get("x-share-host") === "1";
    const isCreate = request.headers.get("x-share-create") === "1";
    const code = request.headers.get("x-share-code");
    if (!isProtocolId(user) || !isIdentityEmail(email) || !isProtocolId(code)) {
      return new Response("bad gateway headers", { status: 400 });
    }

    let core = await this.ensureCore();
    if (!core) {
      // Only a create-endpoint token materializes a session: a host-claim
      // refresh token reconnects to an existing session but can never squat
      // a code its holder did not mint.
      if (!isHost || !isCreate) return new Response("no such session", { status: 404 });
      const persisted = ShareSessionCore.create(code, { user, email }, Date.now());
      await this.ctx.storage.put(SESSION_KEY, persisted);
      core = new ShareSessionCore(persisted);
      this.core = core;
    } else {
      await this.flushRestoreEffects();
    }
    if (isHost && core.persisted.host.user !== user) {
      // A host-claim token for a code that already belongs to someone else.
      // Codes are minted server-side with ~125 bits of entropy, so this is
      // token misuse, not a collision.
      return new Response("not the session host", { status: 403 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const attachment = createSocketAttachment({
      connId: crypto.randomUUID(),
      user,
      email,
      host: isHost,
    });
    this.ctx.acceptWebSocket(server);
    try {
      server.serializeAttachment(serializeSocketAttachment(attachment));
    } catch {
      try {
        server.close(DELIVERY_FAILURE_CLOSE_CODE, DELIVERY_FAILURE_CLOSE_REASON);
      } catch {
        // Already closed.
      }
      return new Response(null, { status: 101, webSocket: client });
    }
    this.sockets.set(attachment.connId, server);
    this.attachments.set(attachment.connId, attachment);
    await this.apply(
      core.connect(attachment.connId, { user, email, hostToken: isHost }, Date.now()),
    );
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const core = await this.ensureCore();
    const attachment = this.attachment(ws);
    if (!core || !attachment) {
      ws.close(1011, "session unavailable");
      return;
    }
    const isHost = attachment.host && core.persisted.host.user === attachment.user;
    if (typeof message !== "string") {
      await this.flushRestoreEffects();
      if (!this.sockets.has(attachment.connId)) return;
      const bytes = new Uint8Array(message);
      const decision = validateBinaryIngress(isHost, bytes);
      if (!decision.ok) {
        await this.closeProtocolSocket(
          ws,
          attachment,
          core,
          decision.code,
          decision.reason,
        );
        return;
      }
      await this.apply(
        core.routeBinary(
          attachment.connId,
          decision.header.ws,
          decision.header.pane,
          bytes,
          decision.header.kind,
        ),
      );
      return;
    }
    const receivedAt = Date.now();
    const messageBytes = utf8ByteLength(message);
    const ingressAccepted =
      isHost || this.ingress.consume(attachment.connId, messageBytes, receivedAt);
    if (message.length >= MAX_JSON_FRAME_BYTES || messageBytes >= MAX_JSON_FRAME_BYTES) {
      await this.flushRestoreEffects();
      if (!this.sockets.has(attachment.connId)) return;
      await this.closeProtocolSocket(ws, attachment, core, 1009, "JSON message too large");
      return;
    }
    const decoded = decodeClientJson(message);
    if (decoded === null) {
      await this.flushRestoreEffects();
      if (!this.sockets.has(attachment.connId)) return;
      if (!ingressAccepted) {
        await this.closeProtocolSocket(
          ws,
          attachment,
          core,
          RATE_LIMIT_CLOSE_CODE,
          RATE_LIMIT_CLOSE_REASON,
        );
        return;
      }
      await this.closeProtocolSocket(ws, attachment, core, 4400, "invalid protocol message");
      return;
    }
    const ack = parseAckMessage(decoded);
    if (ack) {
      const result = releaseDeliveryCredit(ws, attachment, ack.nonce);
      if (result === "released" && !isHost && ingressAccepted) {
        this.ingress.refund(attachment.connId, messageBytes, receivedAt);
      }
      if (result === "serialization-failed") {
        this.logInvariant("delivery_ack_serialize_failed", {});
        await this.closeProtocolSocket(
          ws,
          attachment,
          core,
          DELIVERY_FAILURE_CLOSE_CODE,
          DELIVERY_FAILURE_CLOSE_REASON,
        );
      }
      // A waking ACK releases old persisted credit before snapshots/resync
      // reserve new entries. Unknown/replayed ACKs release nothing.
      await this.flushRestoreEffects();
      if (result === "ignored" && !ingressAccepted && this.sockets.has(attachment.connId)) {
        await this.closeProtocolSocket(
          ws,
          attachment,
          core,
          RATE_LIMIT_CLOSE_CODE,
          RATE_LIMIT_CLOSE_REASON,
        );
      }
      return;
    }
    await this.flushRestoreEffects();
    if (!this.sockets.has(attachment.connId)) return;
    if (!ingressAccepted) {
      await this.closeProtocolSocket(
        ws,
        attachment,
        core,
        RATE_LIMIT_CLOSE_CODE,
        RATE_LIMIT_CLOSE_REASON,
      );
      return;
    }
    const rejectInvalid = async (): Promise<void> => {
      await this.apply([
        {
          kind: "send",
          to: attachment.connId,
          msg: {
            t: "error",
            code: "invalid_message",
            message: "invalid protocol message",
          },
        },
      ]);
      // A backpressured error send already closed the socket as slow_client.
      if (!this.sockets.has(attachment.connId)) return;
      await this.closeProtocolSocket(ws, attachment, core, 4400, "invalid protocol message");
    };
    if (isHost) {
      const parsed = parseHostMessage(decoded);
      if (!parsed) {
        await rejectInvalid();
        return;
      }
      await this.apply(core.handleHost(attachment.connId, parsed));
    } else {
      const parsed = parseGuestMessage(decoded);
      if (!parsed) {
        await rejectInvalid();
        return;
      }
      await this.apply(core.handleGuest(attachment.connId, parsed));
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const core = await this.ensureCore();
    const attachment = this.attachment(ws);
    if (!core || !attachment) return;
    await this.flushRestoreEffects();
    if (!this.sockets.has(attachment.connId)) return;
    this.sockets.delete(attachment.connId);
    this.attachments.delete(attachment.connId);
    this.ingress.remove(attachment.connId);
    await this.apply(core.disconnect(attachment.connId, Date.now()));
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  override async alarm(): Promise<void> {
    const core = await this.ensureCore();
    if (!core) return;
    await this.flushRestoreEffects();
    await this.apply(core.alarm(Date.now()));
  }

  /**
   * Load the core from storage, re-registering any sockets that survived
   * hibernation/eviction. Clients are asked to `resync` volatile state.
   */
  private async ensureCore(): Promise<ShareSessionCore | null> {
    if (this.core && this.restored) return this.core;
    if (!this.core) {
      const stored = await this.ctx.storage.get<unknown>(SESSION_KEY);
      if (stored === undefined) return null;
      const persisted = restorePersistedSession(stored);
      if (!persisted) throw new Error("invalid persisted share session");
      this.core = new ShareSessionCore(persisted);
    }
    if (!this.restored) {
      this.restored = true;
      const survivors: Array<{ id: string; user: string; email: string; hostToken: boolean }> =
        [];
      const seen = new Set<string>();
      for (const ws of this.ctx.getWebSockets()) {
        const attachment = this.attachment(ws);
        if (!attachment || seen.has(attachment.connId)) {
          ws.close(1011, "lost attachment");
          continue;
        }
        seen.add(attachment.connId);
        // Sockets accepted in this instance's lifetime are already registered.
        if (this.sockets.has(attachment.connId)) continue;
        try {
          // Canonicalize legacy attachments and prove the full credit window
          // remains serializable before restoring the socket into the core.
          ws.serializeAttachment(serializeSocketAttachment(attachment));
        } catch {
          ws.close(DELIVERY_FAILURE_CLOSE_CODE, DELIVERY_FAILURE_CLOSE_REASON);
          continue;
        }
        this.sockets.set(attachment.connId, ws);
        this.attachments.set(attachment.connId, attachment);
        survivors.push({
          id: attachment.connId,
          user: attachment.user,
          email: attachment.email,
          hostToken: attachment.host,
        });
      }
      if (survivors.length > 0 || this.core.ended) {
        // Rebuild membership immediately, but defer outbound restore effects.
        // webSocketMessage may be the ACK that woke this instance and must
        // release its persisted entry before new snapshot/resync reservations.
        // Ended state also restores with no sockets so legacy tombstones repair
        // their cleanup alarm on the next wake.
        this.pendingRestoreEffects.push(...this.core.restore(survivors, Date.now()));
      }
    }
    return this.core;
  }

  private attachment(ws: WebSocket): ShareSocketAttachment | null {
    try {
      const parsed = parseSocketAttachment(ws.deserializeAttachment());
      return parsed ? (this.attachments.get(parsed.connId) ?? parsed) : null;
    } catch {
      return null;
    }
  }

  private async closeProtocolSocket(
    ws: WebSocket,
    attachment: ShareSocketAttachment,
    core: ShareSessionCore,
    code: number,
    reason: string,
  ): Promise<void> {
    this.sockets.delete(attachment.connId);
    this.attachments.delete(attachment.connId);
    this.ingress.remove(attachment.connId);
    await this.apply(core.disconnect(attachment.connId, Date.now()));
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  private async apply(effects: Effect[]): Promise<void> {
    await dispatchEffects(effects, {
      core: this.core,
      sockets: this.sockets,
      attachments: this.attachments,
      now: () => Date.now(),
      randomUUID: () => crypto.randomUUID(),
      persist: async (session) => this.ctx.storage.put(SESSION_KEY, session),
      setAlarm: async (at) => this.ctx.storage.setAlarm(at),
      clearAlarm: async () => this.ctx.storage.deleteAlarm(),
      deleteAllStorage: async () => {
        await this.ctx.storage.deleteAll();
        for (const id of new Set([
          ...this.sockets.keys(),
          ...this.attachments.keys(),
        ])) {
          this.ingress.remove(id);
        }
        this.sockets.clear();
        this.attachments.clear();
        this.pendingRestoreEffects = [];
        this.core = null;
        this.restored = false;
      },
      removeSocketState: (id) => this.ingress.remove(id),
      logInvariant: (event, details) => this.logInvariant(event, details),
    });
  }

  private async flushRestoreEffects(): Promise<void> {
    if (this.pendingRestoreEffects.length === 0) return;
    const effects = this.pendingRestoreEffects;
    this.pendingRestoreEffects = [];
    await this.apply(effects);
  }

  private logInvariant(
    event: string,
    details: Readonly<Record<string, number | string>>,
  ): void {
    // Deliberately omit payloads, share codes, connection ids, and identities.
    console.error(JSON.stringify({ scope: "share_delivery", event, ...details }));
  }
}
