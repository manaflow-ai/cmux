// HostRelay Durable Object — one instance per host device.
//
// The object id is derived by the worker from a VERIFIED Stack access token
// (`v2:<stackUserId>:<hostDeviceId>`), so one user's relay can never be
// reached with another user's credentials: isolation is by construction, the
// same property TeamPresence relies on. The DO trusts the identity headers
// the worker sets after token verification; it re-verifies tokens itself
// only for in-band `refresh`.
//
// The object is a dumb relay. It parses control JSON (schema-validated,
// size-bounded) and the 5-byte binary data-frame header, and stores NOTHING
// durable except a monotonic session counter. Terminal replay lives in the
// host's own ring buffers, so a relay restart loses no data: endpoints
// reconnect and resume from their application cursors.
//
// WebSocket Hibernation API throughout: an idle-but-connected host costs no
// duration; attachments carry the tiny per-socket state across hibernation.

import { DurableObject } from "cloudflare:workers";
import {
  BYE_AT_CAPACITY,
  BYE_EXPIRED,
  BYE_HOST_CLOSED,
  BYE_PROTOCOL_ERROR,
  BYE_SUPERSEDED,
  decodeClientControl,
  decodeDataFrame,
  encodeDataFrame,
  HOST_SESSION_ID,
  MAX_CLIENTS,
  MAX_CONTROL_BYTES,
  PING_TEXT,
  PONG_TEXT,
  PROTOCOL_VERSION,
  SESSION_MAX_AGE_MS,
  type RelayRole,
  type ServerControlMessage,
} from "./protocol";
import { verifyStackAccessToken, type StackAuthEnv } from "./stackAuth";

export type RelayEnv = StackAuthEnv;

/** Verified-identity headers set by the worker; the DO never reads client
 * input for these. */
export const RELAY_ROLE_HEADER = "x-relay-role";
export const RELAY_USER_HEADER = "x-relay-user-id";
export const RELAY_HOST_DEVICE_HEADER = "x-relay-host-device-id";
export const RELAY_DEVICE_HEADER = "x-relay-device-id";

const SESSION_COUNTER_KEY = "meta:nextSessionId";
/** WebSocket close code for application-level closes (bye already sent). */
const CLOSE_APP = 1000;

interface SocketAttachment {
  role: RelayRole;
  sessionId: number;
  userId: string;
  hostDeviceId: string;
  deviceId: string;
  /** Epoch ms; the alarm closes the socket past this unless refreshed. */
  deadline: number;
}

function attachment(ws: WebSocket): SocketAttachment | null {
  try {
    const value = ws.deserializeAttachment() as SocketAttachment | null;
    return value && typeof value.sessionId === "number" ? value : null;
  } catch {
    return null;
  }
}

function controlJson(message: ServerControlMessage): string {
  return JSON.stringify(message);
}

function trySend(ws: WebSocket, data: string | Uint8Array): void {
  try {
    ws.send(data as never);
  } catch {
    // Socket already gone; close/error handlers do the bookkeeping.
  }
}

function sendByeAndClose(ws: WebSocket, code: string, reason: string): void {
  trySend(ws, controlJson({ t: "bye", code, reason }));
  try {
    ws.close(CLOSE_APP, code);
  } catch {
    // Already closed.
  }
}

export class HostRelay extends DurableObject<RelayEnv> {
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return Response.json({ error: "expected_websocket" }, { status: 426 });
    }
    const role = request.headers.get(RELAY_ROLE_HEADER);
    const userId = request.headers.get(RELAY_USER_HEADER);
    const hostDeviceId = request.headers.get(RELAY_HOST_DEVICE_HEADER);
    const deviceId = request.headers.get(RELAY_DEVICE_HEADER);
    if ((role !== "host" && role !== "client") || !userId || !hostDeviceId || !deviceId) {
      return Response.json({ error: "missing_identity" }, { status: 400 });
    }

    if (role === "client" && this.clientSockets().length >= MAX_CLIENTS) {
      return Response.json({ error: BYE_AT_CAPACITY }, { status: 429 });
    }

    const sessionId = role === "host" ? HOST_SESSION_ID : await this.nextSessionId();
    const deadline = Date.now() + SESSION_MAX_AGE_MS;

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];

    // Tag by role so hibernation wakeups can find counterparts without
    // deserializing every attachment.
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({
      role,
      sessionId,
      userId,
      hostDeviceId,
      deviceId,
      deadline,
    } satisfies SocketAttachment);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING_TEXT, PONG_TEXT));

    if (role === "host") {
      // Exactly one host socket: a reconnect supersedes the previous one
      // (the old socket may be a half-dead NAT zombie the host itself gave
      // up on).
      for (const existing of this.hostSockets()) {
        if (existing !== server) sendByeAndClose(existing, BYE_SUPERSEDED, "host reconnected");
      }
    }

    const clients = this.clientSockets().filter((ws) => ws !== server);
    const hostPresent = role === "host" ? true : this.hostSockets().length > 0;
    trySend(server, controlJson({
      t: "welcome",
      v: PROTOCOL_VERSION,
      role,
      sessionId,
      deadline,
      hostPresent,
    }));

    if (role === "host") {
      // Replay existing client sessions, then tell the clients.
      for (const ws of clients) {
        const info = attachment(ws);
        if (!info) continue;
        trySend(server, controlJson({ t: "peer_joined", sessionId: info.sessionId, deviceId: info.deviceId }));
        trySend(ws, controlJson({ t: "peer_joined", sessionId: HOST_SESSION_ID, deviceId }));
      }
    } else {
      for (const host of this.hostSockets()) {
        trySend(host, controlJson({ t: "peer_joined", sessionId, deviceId }));
      }
    }

    await this.scheduleAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const info = attachment(ws);
    if (!info) {
      sendByeAndClose(ws, BYE_PROTOCOL_ERROR, "missing session state");
      return;
    }
    if (Date.now() >= info.deadline) {
      this.closeExpired(ws, info);
      return;
    }

    if (typeof message === "string") {
      await this.handleControl(ws, info, message);
      return;
    }

    const frame = decodeDataFrame(message);
    if (!frame) {
      sendByeAndClose(ws, BYE_PROTOCOL_ERROR, "malformed data frame");
      this.notifyPeerLeft(info, BYE_PROTOCOL_ERROR);
      return;
    }

    if (info.role === "client") {
      // Stamp the sender's session id; never trust the wire value.
      const host = this.hostSockets()[0];
      if (!host) return; // No host: drop. Clients track presence via peer_joined/left.
      trySend(host, encodeDataFrame(info.sessionId, frame.payload));
      return;
    }

    // Host -> client, addressed by session id. Unknown session: drop (the
    // client left; the host already got peer_left).
    const target = this.clientSockets().find((candidate) => attachment(candidate)?.sessionId === frame.sessionId);
    if (target) trySend(target, encodeDataFrame(frame.sessionId, frame.payload));
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const info = attachment(ws);
    if (info) this.notifyPeerLeft(info, "closed");
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    const info = attachment(ws);
    if (info) this.notifyPeerLeft(info, "error");
  }

  /** Close sockets past their deadline; reschedule for the next one. */
  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const info = attachment(ws);
      if (info && now >= info.deadline) this.closeExpired(ws, info);
    }
    await this.scheduleAlarm();
  }

  private async handleControl(ws: WebSocket, info: SocketAttachment, message: string): Promise<void> {
    if (message.length > MAX_CONTROL_BYTES) {
      sendByeAndClose(ws, BYE_PROTOCOL_ERROR, "control frame too large");
      this.notifyPeerLeft(info, BYE_PROTOCOL_ERROR);
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(message);
    } catch {
      sendByeAndClose(ws, BYE_PROTOCOL_ERROR, "control frame is not JSON");
      this.notifyPeerLeft(info, BYE_PROTOCOL_ERROR);
      return;
    }
    const decoded = decodeClientControl(parsed);
    if (decoded._tag === "Left") {
      sendByeAndClose(ws, BYE_PROTOCOL_ERROR, "unknown control message");
      this.notifyPeerLeft(info, BYE_PROTOCOL_ERROR);
      return;
    }

    const control = decoded.right;
    if (control.t === "close_session") {
      // Host-only: close one client session. Silently ignored from clients.
      if (info.role !== "host") return;
      const target = this.clientSockets().find(
        (candidate) => attachment(candidate)?.sessionId === control.sessionId,
      );
      if (target) {
        // The runtime fires webSocketClose for this socket too; notifying
        // here once (and tolerating the duplicate) keeps the host informed
        // even when the close handshake never completes.
        const targetInfo = attachment(target);
        sendByeAndClose(target, BYE_HOST_CLOSED, "closed by host");
        if (targetInfo) this.notifyPeerLeft(targetInfo, BYE_HOST_CLOSED);
      }
      return;
    }

    // Role and device identity stay pinned from connect time; the refresh
    // only has to prove the SAME account is still live.
    const verified = await verifyStackAccessToken(this.env, control.accessToken, Date.now());
    if (!verified.ok || verified.userId !== info.userId) {
      // A bad refresh does not kill a live session; the deadline still stands.
      trySend(ws, controlJson({ t: "refresh_ack", deadline: info.deadline }));
      return;
    }
    const deadline = Date.now() + SESSION_MAX_AGE_MS;
    ws.serializeAttachment({ ...info, deadline } satisfies SocketAttachment);
    trySend(ws, controlJson({ t: "refresh_ack", deadline }));
    await this.scheduleAlarm();
  }

  private closeExpired(ws: WebSocket, info: SocketAttachment): void {
    sendByeAndClose(ws, BYE_EXPIRED, "session deadline passed");
    this.notifyPeerLeft(info, BYE_EXPIRED);
  }

  private notifyPeerLeft(info: SocketAttachment, reason: string): void {
    if (info.role === "client") {
      for (const host of this.hostSockets()) {
        trySend(host, controlJson({ t: "peer_left", sessionId: info.sessionId, reason }));
      }
      return;
    }
    for (const client of this.clientSockets()) {
      trySend(client, controlJson({ t: "peer_left", sessionId: HOST_SESSION_ID, reason }));
    }
  }

  private hostSockets(): WebSocket[] {
    return this.ctx.getWebSockets("host");
  }

  private clientSockets(): WebSocket[] {
    return this.ctx.getWebSockets("client");
  }

  private async nextSessionId(): Promise<number> {
    // Persisted so a hibernation or eviction can never reissue a live id.
    const next = ((await this.ctx.storage.get<number>(SESSION_COUNTER_KEY)) ?? 0) + 1;
    await this.ctx.storage.put(SESSION_COUNTER_KEY, next);
    return next;
  }

  private async scheduleAlarm(): Promise<void> {
    const deadlines = this.ctx.getWebSockets()
      .map((ws) => attachment(ws)?.deadline)
      .filter((deadline): deadline is number => typeof deadline === "number");
    if (deadlines.length === 0) return;
    await this.ctx.storage.setAlarm(Math.max(Math.min(...deadlines), Date.now() + 1000));
  }
}
