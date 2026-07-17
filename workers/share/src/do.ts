// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.
//
// ShareSession Durable Object — one instance per share id (idFromName(shareId)).
//
// Relay hub for one shared workspace: a single host lane streams layout,
// terminal bytes, and textbox mirrors; approved viewer lanes receive them.
// Terminal data is NEVER stored here (pure relay); the DO durably keeps only
// the host token hash, per-user join verdicts, and the last 200 chat
// messages, and deletes everything when the session ends.
//
// Authorization happens in the worker before anything reaches this object:
// viewer identity headers are set from a VERIFIED Stack token, never passed
// through from the client. The host lane authenticates here, against the
// stored SHA-256 of the per-session host token minted at create.
//
// Uses the WebSocket hibernation API; participant metadata rides each
// socket's serialized attachment so an evicted DO wakes up with full state.

import { DurableObject } from "cloudflare:workers";
import {
  appendChat,
  CHAT_HISTORY_CAP,
  frameWithinLimit,
  HOST_COLOR,
  HOST_GRACE_MS,
  joinStateForVerdict,
  newTokenBucket,
  parseIncoming,
  sha256Hex,
  tryTakeToken,
  viewerColor,
  type IncomingMessage,
  type JoinState,
  type Participant,
  type StoredChatMessage,
  type TokenBucket,
  type Verdict,
} from "./core";

const HOST_TOKEN_HASH_KEY = "meta:hostTokenHash";
const HOST_PARTICIPANT_KEY = "meta:hostParticipant";
const TITLE_KEY = "meta:title";
const VIEWER_ORDINAL_KEY = "meta:viewerOrdinal";
const CHAT_KEY = "chat";
const VERDICT_PREFIX = "verdict:";

const HOST_TAG = "host";
const VIEWER_TAG = "viewer";

/** Cap concurrent sockets so one session cannot pin unbounded DO memory. */
const MAX_SOCKETS = 64;

type Attachment =
  | { role: "host" }
  | { role: "viewer"; userId: string; participant: Participant; state: JoinState };

export interface CreatorIdentity {
  id: string;
  email: string;
  name: string;
}

function attachment(ws: WebSocket): Attachment | null {
  try {
    return ws.deserializeAttachment() as Attachment | null;
  } catch {
    return null;
  }
}

function safeSend(ws: WebSocket, frame: unknown): void {
  try {
    ws.send(JSON.stringify(frame));
  } catch {
    // Socket already gone; the hibernation API cleans it up.
  }
}

function safeClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // already closed
  }
}

export class ShareSession extends DurableObject {
  /** Cursor rate limiter buckets, keyed by live socket. In-memory only: after
   * hibernation the map is empty and buckets are lazily recreated on the next
   * cursor message, which only ever grants a sender a fresh burst. */
  private cursorBuckets = new Map<WebSocket, TokenBucket>();

  // ---- RPC surface (called by the worker) ----

  /** One-time initialization at create: store the host token HASH (never the
   * token) plus the creator's identity as the host participant (color 0). A
   * second initialize on the same id is refused so an id collision (or a
   * replayed create) can never take over a live session. */
  async initialize(
    hostTokenHash: string,
    creator: CreatorIdentity,
    title: string | undefined,
  ): Promise<{ ok: true } | { ok: false; error: "already_exists" }> {
    const existing = await this.ctx.storage.get<string>(HOST_TOKEN_HASH_KEY);
    if (existing !== undefined) return { ok: false, error: "already_exists" };
    const host: Participant = {
      id: crypto.randomUUID(),
      email: creator.email,
      name: creator.name,
      color: HOST_COLOR,
      role: "host",
    };
    await this.ctx.storage.put({
      [HOST_TOKEN_HASH_KEY]: hostTokenHash,
      [HOST_PARTICIPANT_KEY]: host,
      ...(title !== undefined ? { [TITLE_KEY]: title } : {}),
    });
    return { ok: true };
  }

  // ---- WebSocket upgrades (worker forwards the original Request) ----

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const storedHash = await this.ctx.storage.get<string>(HOST_TOKEN_HASH_KEY);
    if (storedHash === undefined) {
      // Never created, or already ended (end deletes all storage).
      return new Response("not found", { status: 404 });
    }
    if (this.ctx.getWebSockets().length >= MAX_SOCKETS) {
      return new Response("too many connections", { status: 429 });
    }

    const url = new URL(request.url);
    if (url.pathname.endsWith("/host")) {
      return this.acceptHost(url, storedHash);
    }
    return this.acceptViewer(request);
  }

  private async acceptHost(url: URL, storedHash: string): Promise<Response> {
    const token = url.searchParams.get("token") ?? "";
    if (!token || (await sha256Hex(token)) !== storedHash) {
      return new Response("forbidden", { status: 403 });
    }

    // Single active host connection: a new one supersedes the old.
    for (const prior of this.ctx.getWebSockets(HOST_TAG)) {
      safeClose(prior, 1000, "superseded by a new host connection");
    }

    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [HOST_TAG]);
    pair[1].serializeAttachment({ role: "host" } satisfies Attachment);
    // The host is back (or here for the first time): the session is live, so
    // cancel any pending disconnect-grace end.
    await this.ctx.storage.deleteAlarm();
    await this.broadcastPresence();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  private async acceptViewer(request: Request): Promise<Response> {
    // Identity headers are set by the worker from a VERIFIED Stack token.
    const userId = request.headers.get("x-share-user-id") ?? "";
    if (!userId) return new Response("unauthorized", { status: 401 });
    const email = decodeURIComponent(request.headers.get("x-share-email") ?? "");
    const name = decodeURIComponent(request.headers.get("x-share-name") ?? "");

    const verdict = await this.ctx.storage.get<Verdict>(`${VERDICT_PREFIX}${userId}`);
    const state = joinStateForVerdict(verdict);

    const ordinal = (await this.ctx.storage.get<number>(VIEWER_ORDINAL_KEY)) ?? 0;
    await this.ctx.storage.put(VIEWER_ORDINAL_KEY, ordinal + 1);
    const participant: Participant = {
      id: crypto.randomUUID(),
      email,
      name: name || email,
      color: viewerColor(ordinal),
      role: "viewer",
    };

    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1], [VIEWER_TAG]);
    pair[1].serializeAttachment(
      { role: "viewer", userId, participant, state } satisfies Attachment,
    );

    safeSend(pair[1], { type: "join_state", state });
    if (state === "denied") {
      safeClose(pair[1], 1000, "join denied");
    } else if (state === "approved") {
      // Previously approved user reconnecting: admit immediately.
      await this.admitViewer(pair[1], participant);
    } else {
      // Pending: ask the (possibly momentarily disconnected) host.
      this.sendToHost({
        type: "join_request",
        requestId: participant.id,
        email,
        name: participant.name,
      });
    }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** Post-approval admission: ask the host for a targeted snapshot, replay
   * stored chat history to this viewer, and broadcast presence. */
  private async admitViewer(ws: WebSocket, participant: Participant): Promise<void> {
    this.sendToHost({ type: "sync_request", participantId: participant.id });
    const history =
      (await this.ctx.storage.get<StoredChatMessage[]>(CHAT_KEY)) ?? [];
    for (const message of history) safeSend(ws, message);
    await this.broadcastPresence();
  }

  // ---- Inbound frames ----

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const meta = attachment(ws);
    if (meta === null) return;

    const byteLength = typeof message === "string" ? message.length : message.byteLength;
    if (!frameWithinLimit(meta.role, byteLength)) {
      safeClose(ws, 1009, "frame too large");
      return;
    }

    let body: unknown;
    try {
      body = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      return; // not JSON; drop
    }
    const parsed = parseIncoming(meta.role, body);
    if (parsed === null) return; // unknown/ill-typed/forbidden-for-role; drop

    if (meta.role === "host") {
      await this.handleHostMessage(ws, parsed);
      return;
    }
    // Viewer lane: parseIncoming already restricted to cursor/chat.
    if (meta.state !== "approved") {
      // A pending or denied viewer has no voice yet; cursor from anyone means
      // host or APPROVED viewer (DESIGN.md).
      return;
    }
    if (parsed.type === "cursor") {
      this.relayCursor(ws, meta.participant.id, parsed.x, parsed.y);
    } else if (parsed.type === "chat") {
      await this.relayChat(meta.participant.id, parsed.text, parsed.x, parsed.y);
    }
  }

  private async handleHostMessage(ws: WebSocket, message: IncomingMessage): Promise<void> {
    switch (message.type) {
      case "join_response":
        await this.handleJoinResponse(message.requestId, message.allow);
        return;
      case "snapshot": {
        // Targeted: forwarded ONLY to the requested participant.
        const target = this.findViewer(message.to);
        if (target !== null) {
          safeSend(target.ws, { type: "snapshot", workspace: message.workspace });
        }
        return;
      }
      case "layout":
      case "term":
      case "term_resize":
      case "textbox":
        this.broadcastToApprovedViewers(message);
        return;
      case "cursor": {
        const host = await this.hostParticipant();
        if (host !== null) this.relayCursor(ws, host.id, message.x, message.y);
        return;
      }
      case "chat": {
        const host = await this.hostParticipant();
        if (host !== null) await this.relayChat(host.id, message.text, message.x, message.y);
        return;
      }
      case "end":
        await this.endSession();
        return;
      default:
        return;
    }
  }

  private async handleJoinResponse(requestId: string, allow: boolean): Promise<void> {
    const target = this.findViewer(requestId);
    if (target === null || target.meta.state !== "pending") return;
    const verdict: Verdict = allow ? "approved" : "denied";
    // Remember the verdict per Stack user id for the life of the session.
    await this.ctx.storage.put(`${VERDICT_PREFIX}${target.meta.userId}`, verdict);
    const nextState: JoinState = verdict;
    target.ws.serializeAttachment({ ...target.meta, state: nextState } satisfies Attachment);
    safeSend(target.ws, { type: "join_state", state: nextState });
    if (allow) {
      await this.admitViewer(target.ws, target.meta.participant);
    } else {
      safeClose(target.ws, 1000, "join denied");
    }
  }

  /** Stamp `participantId` and rebroadcast to everyone else, 30/s per sender;
   * excess is silently dropped. */
  private relayCursor(sender: WebSocket, participantId: string, x: number, y: number): void {
    const now = Date.now();
    let bucket = this.cursorBuckets.get(sender);
    if (bucket === undefined) {
      bucket = newTokenBucket(now);
      this.cursorBuckets.set(sender, bucket);
    }
    if (!tryTakeToken(bucket, now)) return;
    const frame = { type: "cursor", participantId, x, y };
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === sender) continue;
      if (!this.canReceive(ws)) continue;
      safeSend(ws, frame);
    }
  }

  /** Stamp `participantId` + `ts`, persist (capped at 200), and broadcast to
   * everyone including the sender. */
  private async relayChat(participantId: string, text: string, x: number, y: number): Promise<void> {
    const entry: StoredChatMessage = {
      type: "chat",
      participantId,
      ts: Date.now(),
      text,
      x,
      y,
    };
    const history = (await this.ctx.storage.get<StoredChatMessage[]>(CHAT_KEY)) ?? [];
    await this.ctx.storage.put(CHAT_KEY, appendChat(history, entry, CHAT_HISTORY_CAP));
    for (const ws of this.ctx.getWebSockets()) {
      if (!this.canReceive(ws)) continue;
      safeSend(ws, entry);
    }
  }

  // ---- Disconnects, session end, alarm ----

  override async webSocketClose(ws: WebSocket): Promise<void> {
    this.cursorBuckets.delete(ws);
    const meta = attachment(ws);
    safeClose(ws, 1000, "closing");
    if (meta?.role === "host") {
      // The closing socket is still in getWebSockets() during this callback,
      // so count the OTHER host sockets (a superseded socket closing must not
      // arm the end alarm while the new host is live).
      const otherHosts = this.ctx.getWebSockets(HOST_TAG).filter((socket) => socket !== ws);
      if (otherHosts.length === 0) {
        // Grace window for the host to return before the session ends.
        await this.ctx.storage.setAlarm(Date.now() + HOST_GRACE_MS);
      }
      await this.broadcastPresence(ws);
      return;
    }
    if (meta?.role === "viewer" && meta.state === "approved") {
      await this.broadcastPresence(ws);
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }

  override async alarm(): Promise<void> {
    // Host never returned within the grace window: end the session. If the
    // host DID return, acceptHost deleted the alarm, so firing means gone.
    if (this.ctx.getWebSockets(HOST_TAG).length > 0) return;
    await this.endSession();
  }

  /** Broadcast `ended`, close every socket, and delete all durable state. */
  private async endSession(): Promise<void> {
    const frame = { type: "ended" };
    for (const ws of this.ctx.getWebSockets()) {
      safeSend(ws, frame);
      safeClose(ws, 1000, "session ended");
    }
    this.cursorBuckets.clear();
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  // ---- Internals ----

  private async hostParticipant(): Promise<Participant | null> {
    return (await this.ctx.storage.get<Participant>(HOST_PARTICIPANT_KEY)) ?? null;
  }

  /** Send one frame to the live host socket(s). Best-effort: a host in its
   * disconnect-grace window simply misses it (the viewer's approval replays
   * via sync_request when it reconnects only if re-triggered; a pending
   * join_request is re-sent by the viewer reconnecting). */
  private sendToHost(frame: unknown): void {
    for (const ws of this.ctx.getWebSockets(HOST_TAG)) {
      safeSend(ws, frame);
    }
  }

  private findViewer(participantId: string): { ws: WebSocket; meta: Attachment & { role: "viewer" } } | null {
    for (const ws of this.ctx.getWebSockets(VIEWER_TAG)) {
      const meta = attachment(ws);
      if (meta?.role === "viewer" && meta.participant.id === participantId) {
        return { ws, meta };
      }
    }
    return null;
  }

  /** Whether this socket may receive session traffic: the host always, a
   * viewer only once approved (pending/denied viewers see nothing but their
   * own join_state). */
  private canReceive(ws: WebSocket): boolean {
    const meta = attachment(ws);
    if (meta === null) return false;
    return meta.role === "host" || meta.state === "approved";
  }

  private broadcastToApprovedViewers(frame: unknown): void {
    for (const ws of this.ctx.getWebSockets(VIEWER_TAG)) {
      const meta = attachment(ws);
      if (meta?.role !== "viewer" || meta.state !== "approved") continue;
      safeSend(ws, frame);
    }
  }

  /** Full participant list (host when connected + approved connected viewers)
   * to the host and every approved viewer. `closing` excludes a socket that
   * is mid-close (webSocketClose still lists it). */
  private async broadcastPresence(closing?: WebSocket): Promise<void> {
    const participants: Participant[] = [];
    const hostLive = this.ctx
      .getWebSockets(HOST_TAG)
      .some((ws) => ws !== closing);
    if (hostLive) {
      const host = await this.hostParticipant();
      if (host !== null) participants.push(host);
    }
    for (const ws of this.ctx.getWebSockets(VIEWER_TAG)) {
      if (ws === closing) continue;
      const meta = attachment(ws);
      if (meta?.role === "viewer" && meta.state === "approved") {
        participants.push(meta.participant);
      }
    }
    const frame = { type: "presence", participants };
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === closing) continue;
      if (!this.canReceive(ws)) continue;
      safeSend(ws, frame);
    }
  }
}
