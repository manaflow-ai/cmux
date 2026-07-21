import { DurableObject } from "cloudflare:workers";
import type { ShareOwnerIndex } from "./shareOwnerIndex";
import {
  canQueueSocketFrame,
  consumeEventBudget,
  consumeMessageBudget,
  type EventWindow,
} from "./messageBudget";
import {
  SHARE_WEBSOCKET_PROTOCOL,
  allowedClientType,
  isOrderedHostStreamType,
  serverEnvelope,
  type Participant,
} from "./protocol";
import {
  canCreateViewer,
  colorForUser,
  decideViewer,
  hostAvailabilityExpired,
  hostIsUnavailable,
  hostReconnectDeadline,
  MAX_DENIED_VIEWERS,
  MAX_VIEWERS,
  nextRoomAlarm,
  pendingViewerTicketIsFresh,
  viewerConnectionExpiry,
  type ShareRoomMetadata,
  type ViewerState,
} from "./state";
import {
  normalizedChat,
  parseMessage,
  selectedTerminalTargetsFromWorkspacePayload,
  validAccessDecisionPayload,
  validPointerPayload,
  validResyncPayload,
  validTerminalInputPayload,
  validTextOperationPayload,
  validTextSelectionPayload,
  validTerminalVTPayload,
} from "./validate";

const META_KEY = "room:metadata";
const CHAT_KEY = "room:chat";
const VIEWER_PREFIX = "viewer:";
const NONCE_PREFIX = "nonce:";
const MAX_CHAT_MESSAGES = 50;
const MAX_RECENT_NONCES = 128;
const POINTER_INTERVAL_MS = 30;
const CHAT_INTERVAL_MS = 750;
const SELECTION_INTERVAL_MS = 30;
const RESYNC_INTERVAL_MS = 2_000;
const MAX_SOCKET_BUFFERED_BYTES = 2 * 1_024 * 1_024;
const VIEWER_REALTIME_EVENTS_PER_SECOND = 240;
const HOST_BROADCAST_EVENTS_PER_SECOND = 120;
const VIEWER_TERMINAL_INPUT_EVENTS_PER_SECOND = 240;
const HOST_BUDGETED_BROADCAST_TYPES = new Set([
  "workspace.snapshot",
  "workspace.layout",
  "terminal.vt",
  "panel.frame",
  "textbox.document",
]);

type EncodedServerFrame = {
  readonly text: string;
  readonly byteLength: number;
};

export type CreateRoomInput = ShareRoomMetadata;

export type ShareRoomEnv = {
  readonly SHARE_OWNER_INDEX: DurableObjectNamespace<ShareOwnerIndex>;
};

type Principal = {
  readonly userId: string;
  readonly email: string;
  readonly displayName: string;
  readonly nonceHash?: string;
  readonly ticketExpiresAt?: number;
};

type SocketAttachment = Principal & {
  readonly role: "host" | "viewer";
  readonly connectionId: string;
  readonly color: number;
  readonly approved: boolean;
  readonly expiresAt: number;
  readonly lastClientSeq: number;
  readonly lastPointerAt: number;
  readonly lastChatAt: number;
  readonly lastSelectionAt: number;
  readonly lastResyncAt: number;
  readonly messageWindowStartedAt: number;
  readonly messageCount: number;
  readonly messageBytes: number;
  readonly sharedLayoutRevision?: number;
  readonly sharedTerminalSurfaceIds?: readonly string[];
};

type ChatMessage = {
  readonly id: string;
  readonly userId: string;
  readonly displayName: string;
  readonly color: number;
  readonly text: string;
  readonly createdAt: number;
};

export class ShareRoom extends DurableObject<ShareRoomEnv> {
  private serverSeq = Date.now() * 1_000;
  private hostAvailabilityDeadline: number | null | undefined;
  private viewerRealtimeWindow: EventWindow = { startedAt: 0, count: 0 };
  private viewerTerminalInputWindow: EventWindow = { startedAt: 0, count: 0 };
  private hostBroadcastWindow: EventWindow = { startedAt: 0, count: 0 };

  async create(input: CreateRoomInput): Promise<{ ok: true } | { ok: false; error: string }> {
    const existing = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    if (existing) return { ok: false, error: "share_exists" };
    await this.ctx.storage.put(META_KEY, input);
    this.hostAvailabilityDeadline = hostReconnectDeadline(input);
    await this.ctx.storage.setAlarm(nextRoomAlarm(input));
    return { ok: true };
  }

  async end(ownerUserId: string, hostCapabilityHash: string): Promise<boolean> {
    const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    if (
      !metadata ||
      metadata.owner.userId !== ownerUserId ||
      metadata.hostCapabilityHash !== hostCapabilityHash
    ) return false;
    await this.endRoom("host_ended");
    return true;
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "upgrade_required" }, 426);
    }
    const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    if (!metadata || metadata.status !== "active") return json({ error: "share_not_found" }, 404);
    if (metadata.expiresAt <= Date.now()) {
      await this.endRoom("expired");
      return json({ error: "share_expired" }, 410);
    }
    this.hostAvailabilityDeadline = hostIsUnavailable(metadata) ? hostReconnectDeadline(metadata) : null;
    if (this.hostAvailabilityDeadline !== null && this.hostAvailabilityDeadline <= Date.now()) {
      await this.endRoom("host_ended");
      return json({ error: "share_expired" }, 410);
    }
    const role = request.headers.get("x-cmux-share-role");
    const principal = decodePrincipal(request.headers.get("x-cmux-share-principal"));
    if (!principal || (role !== "host" && role !== "viewer")) {
      return json({ error: "unauthorized" }, 401);
    }
    if (role === "host") return await this.connectHost(request, metadata, principal);
    return this.connectViewer(metadata, principal);
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = socketAttachment(ws);
    if (!attachment || attachment.expiresAt <= Date.now()) {
      closeSocket(ws, 4003, "expired");
      return;
    }
    if (!await this.hostIsWithinGrace()) {
      await this.endRoom("host_ended");
      return;
    }
    const messageBytes = typeof message === "string"
      ? new TextEncoder().encode(message).byteLength
      : message.byteLength;
    const envelope = parseMessage(message);
    if (
      !envelope ||
      envelope.seq <= attachment.lastClientSeq ||
      !allowedClientType(attachment.role, attachment.approved, envelope.type)
    ) return;

    const now = Date.now();
    const budget = consumeMessageBudget({
      startedAt: attachment.messageWindowStartedAt,
      count: attachment.messageCount,
      bytes: attachment.messageBytes,
    }, attachment.role, messageBytes, now);
    if (!budget.ok) {
      closeSocket(ws, 4008, "rate_limited");
      return;
    }
    let nextAttachment = {
      ...attachment,
      lastClientSeq: envelope.seq,
      messageWindowStartedAt: budget.window.startedAt,
      messageCount: budget.window.count,
      messageBytes: budget.window.bytes,
    };
    // Consume the sequence and room-wide message budget even when a type-specific
    // validator or cooldown rejects the payload below.
    persistAttachment(ws, nextAttachment);
    if (envelope.type === "presence.pointer") {
      if (!validPointerPayload(envelope.payload) || now - attachment.lastPointerAt < POINTER_INTERVAL_MS) return;
      nextAttachment = { ...nextAttachment, lastPointerAt: now };
    }
    if (envelope.type === "chat.message") {
      if (now - attachment.lastChatAt < CHAT_INTERVAL_MS) return;
      nextAttachment = { ...nextAttachment, lastChatAt: now };
    }
    if (envelope.type === "textbox.selection") {
      if (!validTextSelectionPayload(envelope.payload) || now - attachment.lastSelectionAt < SELECTION_INTERVAL_MS) return;
      nextAttachment = { ...nextAttachment, lastSelectionAt: now };
    }
    if (attachment.role === "viewer" && envelope.type === "textbox.operation") {
      if (!validTextOperationPayload(envelope.payload, attachment.connectionId)) return;
    }
    if (attachment.role === "viewer" && envelope.type === "terminal.input") {
      if (!validTerminalInputPayload(envelope.payload) || !this.isCurrentTerminalInputTarget(envelope.payload)) return;
    }
    if (attachment.role === "viewer" && envelope.type === "workspace.resync.request") {
      if (!validResyncPayload(envelope.payload) || now - attachment.lastResyncAt < RESYNC_INTERVAL_MS) return;
      nextAttachment = { ...nextAttachment, lastResyncAt: now };
    }
    if (attachment.role === "host" && envelope.type === "access.decision" &&
        !validAccessDecisionPayload(envelope.payload)) return;
    if (attachment.role === "host" && envelope.type === "terminal.vt" &&
        !validTerminalVTPayload(envelope.payload)) {
      closeSocket(ws, 4002, "invalid_terminal_stream");
      return;
    }
    if (attachment.role === "host" &&
        (envelope.type === "workspace.snapshot" || envelope.type === "workspace.layout")) {
      const targets = selectedTerminalTargetsFromWorkspacePayload(envelope.payload);
      if (!targets) {
        closeSocket(ws, 4002, "invalid_workspace_scene");
        return;
      }
      nextAttachment = {
        ...nextAttachment,
        sharedLayoutRevision: targets.layoutRevision,
        sharedTerminalSurfaceIds: targets.surfaceIds,
      };
    }
    if (attachment.role === "host" && envelope.type === "share.end") {
      if (Object.keys(envelope.payload).length !== 0) return;
      await this.endRoom("host_ended");
      return;
    }
    persistAttachment(ws, nextAttachment);

    if (attachment.role === "host" && envelope.type === "access.decision") {
      await this.handleAccessDecision(envelope.payload);
      return;
    }
    if (envelope.type === "chat.message") {
      await this.handleChat(attachment, envelope.payload.text);
      return;
    }
    if (envelope.type === "presence.pointer") {
      if (attachment.role === "viewer" && !this.consumeViewerRealtime(now)) return;
      if (attachment.role === "host" && !this.consumeHostBroadcast(now)) return;
      this.broadcastApproved("presence.pointer", {
        ...envelope.payload,
        participant: participantFrom(attachment),
      }, ws);
      return;
    }
    if (envelope.type === "textbox.selection") {
      if (attachment.role === "viewer" && !this.consumeViewerRealtime(now)) return;
      if (attachment.role === "host" && !this.consumeHostBroadcast(now)) return;
      this.broadcastApproved("textbox.selection", {
        ...envelope.payload,
        participant: participantFrom(attachment),
      }, ws);
      return;
    }
    if (attachment.role === "viewer" && envelope.type === "textbox.operation") {
      if (!this.consumeViewerRealtime(now)) {
        closeSocket(ws, 4008, "room_rate_limited");
        return;
      }
      this.sendToHosts("textbox.operation.request", {
        ...envelope.payload,
        participant: participantFrom(attachment),
      });
      return;
    }
    if (attachment.role === "viewer" && envelope.type === "terminal.input") {
      if (!this.consumeViewerTerminalInput(now)) {
        closeSocket(ws, 4008, "terminal_input_rate_limited");
        return;
      }
      this.sendToHosts("terminal.input.request", {
        input: envelope.payload,
        participant: participantFrom(attachment),
      });
      return;
    }
    if (attachment.role === "viewer" && envelope.type === "workspace.resync.request") {
      this.sendToHosts("workspace.snapshot.request", {
        connectionId: attachment.connectionId,
        reason: envelope.payload.reason ?? "viewer_request",
      });
      return;
    }
    if (attachment.role === "host") {
      if (HOST_BUDGETED_BROADCAST_TYPES.has(envelope.type) && !this.consumeHostBroadcast(now)) {
        if (isOrderedHostStreamType(envelope.type)) {
          closeSocket(ws, 4008, "terminal_resync_required");
        }
        return;
      }
      this.broadcastViewers(envelope.type, envelope.payload);
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = socketAttachment(ws);
    if (attachment?.approved) {
      this.broadcastApproved("presence.left", { participant: participantFrom(attachment) }, ws);
    }
    if (attachment?.role === "host") await this.noteHostDisconnected(ws);
    closeSocket(ws, 1000, "closed");
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    const attachment = socketAttachment(ws);
    if (attachment?.approved) {
      this.broadcastApproved("presence.left", { participant: participantFrom(attachment) }, ws);
    }
    if (attachment?.role === "host") await this.noteHostDisconnected(ws);
    closeSocket(ws, 1011, "socket_error");
  }

  override async alarm(): Promise<void> {
    const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    const now = Date.now();
    if (!metadata || metadata.expiresAt <= now) {
      await this.endRoom("expired");
    } else if (hostAvailabilityExpired(metadata, now)) {
      await this.endRoom("host_ended");
    } else {
      await this.ctx.storage.setAlarm(nextRoomAlarm(metadata));
    }
  }

  private async connectHost(
    request: Request,
    metadata: ShareRoomMetadata,
    principal: Principal,
  ): Promise<Response> {
    if (
      principal.userId !== metadata.owner.userId ||
      request.headers.get("x-cmux-share-capability-hash") !== metadata.hostCapabilityHash
    ) return json({ error: "forbidden" }, 403);
    for (const socket of this.ctx.getWebSockets()) {
      const existing = socketAttachment(socket);
      if (existing?.role === "host") closeSocket(socket, 4001, "host_reconnected");
    }
    const reconnected = {
      ...metadata,
      hostConnectedAt: metadata.hostConnectedAt ?? Date.now(),
      hostDisconnectedAt: undefined,
    };
    await this.ctx.storage.put(META_KEY, reconnected);
    this.hostAvailabilityDeadline = null;
    await this.ctx.storage.setAlarm(reconnected.expiresAt);
    const { client, server } = websocketPair();
    const attachment: SocketAttachment = {
      ...principal,
      role: "host",
      connectionId: crypto.randomUUID(),
      color: colorForUser(principal.userId),
      approved: true,
      expiresAt: metadata.expiresAt,
      lastClientSeq: -1,
      lastPointerAt: 0,
      lastChatAt: 0,
      lastSelectionAt: 0,
      lastResyncAt: 0,
      messageWindowStartedAt: Date.now(),
      messageCount: 0,
      messageBytes: 0,
    };
    this.ctx.acceptWebSocket(server);
    persistAttachment(server, attachment);
    this.send(server, "host.ready", {
      shareId: metadata.shareId,
      workspaceId: metadata.workspaceId,
      workspaceTitle: metadata.workspaceTitle,
      expiresAt: metadata.expiresAt,
      participant: participantFrom(attachment),
    });
    await this.sendApprovedBootstrap(server);
    this.broadcastApproved("presence.joined", { participant: participantFrom(attachment) }, server);
    void this.sendPendingViewers(server);
    return websocketResponse(client);
  }

  private async noteHostDisconnected(excluding: WebSocket): Promise<void> {
    if (this.ctx.getWebSockets().some((socket) =>
      socket !== excluding && socketAttachment(socket)?.role === "host"
    )) return;
    const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    if (!metadata || metadata.status !== "active" || metadata.hostDisconnectedAt !== undefined) return;
    const next = { ...metadata, hostDisconnectedAt: Date.now() };
    await this.ctx.storage.put(META_KEY, next);
    this.hostAvailabilityDeadline = hostReconnectDeadline(next);
    await this.ctx.storage.setAlarm(this.hostAvailabilityDeadline);
  }

  private async connectViewer(metadata: ShareRoomMetadata, principal: Principal): Promise<Response> {
    const ticketExpiresAt = principal.ticketExpiresAt;
    if (!principal.nonceHash || ticketExpiresAt === undefined ||
        !pendingViewerTicketIsFresh(ticketExpiresAt, Date.now())) {
      return json({ error: "unauthorized" }, 401);
    }
    await this.pruneRecentNonces();
    const nonceKey = `${NONCE_PREFIX}${principal.nonceHash}`;
    if (await this.ctx.storage.get(nonceKey)) return json({ error: "ticket_replayed" }, 409);
    const viewerKey = `${VIEWER_PREFIX}${principal.userId}`;
    const existing = await this.ctx.storage.get<ViewerState>(viewerKey);
    if (existing?.access === "denied") return json({ error: "access_denied" }, 403);
    const viewers = [...(await this.ctx.storage.list<ViewerState>({ prefix: VIEWER_PREFIX })).values()];
    if (!existing) {
      const capacity = canCreateViewer(viewers);
      if (capacity !== "ok") return json({ error: capacity }, 429);
    }

    await this.ctx.storage.put(nonceKey, ticketExpiresAt);
    const viewer: ViewerState = existing ?? {
      userId: principal.userId,
      email: principal.email,
      displayName: principal.displayName,
      color: colorForUser(principal.userId),
      access: "pending",
      requestedAt: Date.now(),
    };
    await this.ctx.storage.put(viewerKey, viewer);
    for (const socket of this.ctx.getWebSockets()) {
      const current = socketAttachment(socket);
      if (current?.role === "viewer" && current.userId === principal.userId) {
        closeSocket(socket, 4001, "viewer_reconnected");
      }
    }

    const { client, server } = websocketPair();
    const attachment: SocketAttachment = {
      ...principal,
      role: "viewer",
      connectionId: crypto.randomUUID(),
      color: viewer.color,
      approved: viewer.access === "approved",
      expiresAt: viewerConnectionExpiry(viewer.access, metadata.expiresAt, ticketExpiresAt),
      lastClientSeq: -1,
      lastPointerAt: 0,
      lastChatAt: 0,
      lastSelectionAt: 0,
      lastResyncAt: 0,
      messageWindowStartedAt: Date.now(),
      messageCount: 0,
      messageBytes: 0,
    };
    this.ctx.acceptWebSocket(server);
    persistAttachment(server, attachment);
    this.send(server, "access.status", {
      status: viewer.access,
      participant: participantFrom(attachment),
    });
    if (attachment.approved) {
      await this.sendApprovedBootstrap(server);
      this.sendToHosts("workspace.snapshot.request", {
        connectionId: attachment.connectionId,
        reason: "viewer_connected",
      });
    } else {
      this.sendToHosts("access.requested", {
        connectionId: attachment.connectionId,
        userId: viewer.userId,
        email: viewer.email,
        displayName: viewer.displayName,
        color: viewer.color,
        requestedAt: viewer.requestedAt,
      });
    }
    return websocketResponse(client);
  }

  private async handleAccessDecision(payload: Record<string, unknown>): Promise<void> {
    const userId = typeof payload.userId === "string" ? payload.userId : null;
    const decision = payload.decision === "allow" || payload.decision === "deny" ? payload.decision : null;
    if (!userId || !decision) return;
    const key = `${VIEWER_PREFIX}${userId}`;
    const existing = await this.ctx.storage.get<ViewerState>(key);
    if (!existing) return;
    if (decision === "allow") {
      const viewers = await this.ctx.storage.list<ViewerState>({ prefix: VIEWER_PREFIX });
      const approved = [...viewers.values()].filter((viewer) => viewer.access === "approved").length;
      if (approved >= MAX_VIEWERS) {
        this.sendToHosts("access.decision.rejected", { userId, reason: "room_full" });
        return;
      }
    }
    const next = decideViewer(existing, decision, Date.now());
    if (next === existing) return;
    await this.ctx.storage.put(key, next);
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socketAttachment(socket);
      if (attachment?.role !== "viewer" || attachment.userId !== userId) continue;
      if (next.access === "approved") {
        if (!pendingViewerTicketIsFresh(attachment.ticketExpiresAt, Date.now())) {
          closeSocket(socket, 4003, "fresh_auth_required");
          continue;
        }
        const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
        if (!metadata || metadata.status !== "active") {
          closeSocket(socket, 4000, "share_ended");
          continue;
        }
        const approvedAttachment = {
          ...attachment,
          approved: true,
          expiresAt: metadata.expiresAt,
        };
        persistAttachment(socket, approvedAttachment);
        this.send(socket, "access.status", {
          status: "approved",
          participant: participantFrom(approvedAttachment),
        });
        await this.sendApprovedBootstrap(socket);
        this.broadcastApproved("presence.joined", {
          participant: participantFrom(approvedAttachment),
        }, socket);
        this.sendToHosts("workspace.snapshot.request", {
          connectionId: attachment.connectionId,
          reason: "viewer_approved",
        });
      } else {
        this.send(socket, "access.status", { status: "denied" });
        closeSocket(socket, 4003, "access_denied");
      }
    }
    if (next.access === "denied") await this.pruneDeniedViewers();
    this.sendToHosts("access.decided", { userId, decision });
  }

  private async handleChat(attachment: SocketAttachment, rawText: unknown): Promise<void> {
    const text = normalizedChat(rawText);
    if (!text) return;
    const message: ChatMessage = {
      id: crypto.randomUUID(),
      userId: attachment.userId,
      displayName: attachment.displayName,
      color: attachment.color,
      text,
      createdAt: Date.now(),
    };
    const current = await this.ctx.storage.get<ChatMessage[]>(CHAT_KEY) ?? [];
    await this.ctx.storage.put(CHAT_KEY, [...current, message].slice(-MAX_CHAT_MESSAGES));
    this.broadcastApproved("chat.message", message);
  }

  private async sendPendingViewers(host: WebSocket): Promise<void> {
    const viewers = await this.ctx.storage.list<ViewerState>({ prefix: VIEWER_PREFIX });
    for (const viewer of viewers.values()) {
      if (viewer.access !== "pending") continue;
      this.send(host, "access.requested", {
        userId: viewer.userId,
        email: viewer.email,
        displayName: viewer.displayName,
        color: viewer.color,
        requestedAt: viewer.requestedAt,
      });
    }
  }

  private async sendApprovedBootstrap(socket: WebSocket): Promise<void> {
    const participants = this.ctx.getWebSockets()
      .map(socketAttachment)
      .filter((value): value is SocketAttachment => !!value?.approved)
      .map(participantFrom);
    this.send(socket, "presence.snapshot", { participants });
    this.send(socket, "chat.snapshot", {
      messages: await this.ctx.storage.get<ChatMessage[]>(CHAT_KEY) ?? [],
    });
  }

  private async pruneRecentNonces(): Promise<void> {
    const nonces = await this.ctx.storage.list<number>({ prefix: NONCE_PREFIX });
    const now = Date.now();
    const current = [...nonces].filter(([, expiresAt]) => expiresAt > now);
    const stale = [...nonces].filter(([, expiresAt]) => expiresAt <= now).map(([key]) => key);
    const overflow = current
      .sort((left, right) => left[1] - right[1])
      .slice(0, Math.max(0, current.length - MAX_RECENT_NONCES + 1))
      .map(([key]) => key);
    const keys = [...stale, ...overflow];
    if (keys.length > 0) await this.ctx.storage.delete(keys);
  }

  private async pruneDeniedViewers(): Promise<void> {
    const viewers = await this.ctx.storage.list<ViewerState>({ prefix: VIEWER_PREFIX });
    const denied = [...viewers]
      .filter(([, viewer]) => viewer.access === "denied")
      .sort((left, right) =>
        (right[1].decidedAt ?? right[1].requestedAt) - (left[1].decidedAt ?? left[1].requestedAt));
    const stale = denied.slice(MAX_DENIED_VIEWERS).map(([key]) => key);
    if (stale.length > 0) await this.ctx.storage.delete(stale);
  }

  private broadcastViewers(type: string, payload: unknown): void {
    const frame = this.encodeFrame(type, payload);
    if (!frame) return;
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socketAttachment(socket);
      if (attachment?.role === "viewer" && attachment.approved) this.sendEncoded(socket, frame);
    }
  }

  private broadcastApproved(type: string, payload: unknown, excluding?: WebSocket): void {
    const frame = this.encodeFrame(type, payload);
    if (!frame) return;
    for (const socket of this.ctx.getWebSockets()) {
      if (socket === excluding) continue;
      const attachment = socketAttachment(socket);
      if (attachment?.approved) this.sendEncoded(socket, frame);
    }
  }

  private sendToHosts(type: string, payload: unknown): void {
    const frame = this.encodeFrame(type, payload);
    if (!frame) return;
    for (const socket of this.ctx.getWebSockets()) {
      if (socketAttachment(socket)?.role === "host") this.sendEncoded(socket, frame);
    }
  }

  private send(socket: WebSocket, type: string, payload: unknown): void {
    const frame = this.encodeFrame(type, payload);
    if (frame) this.sendEncoded(socket, frame);
  }

  private encodeFrame(type: string, payload: unknown): EncodedServerFrame | null {
    try {
      const text = JSON.stringify(serverEnvelope(type, this.nextServerSeq(), payload));
      return { text, byteLength: new TextEncoder().encode(text).byteLength };
    } catch {
      return null;
    }
  }

  private sendEncoded(socket: WebSocket, frame: EncodedServerFrame): void {
    try {
      if (socket.readyState !== WebSocket.OPEN) return;
      const bufferedAmount = (socket as WebSocket & { readonly bufferedAmount?: number }).bufferedAmount;
      if (!canQueueSocketFrame(bufferedAmount, frame.byteLength, MAX_SOCKET_BUFFERED_BYTES)) {
        closeSocket(socket, 4008, "slow_client");
        return;
      }
      socket.send(frame.text);
    } catch {
      // The hibernation runtime removes closed sockets from getWebSockets().
    }
  }

  private consumeViewerRealtime(now: number): boolean {
    const result = consumeEventBudget(this.viewerRealtimeWindow, VIEWER_REALTIME_EVENTS_PER_SECOND, now);
    if (!result.ok) return false;
    this.viewerRealtimeWindow = result.window;
    return true;
  }

  private consumeViewerTerminalInput(now: number): boolean {
    const result = consumeEventBudget(
      this.viewerTerminalInputWindow,
      VIEWER_TERMINAL_INPUT_EVENTS_PER_SECOND,
      now,
    );
    if (!result.ok) return false;
    this.viewerTerminalInputWindow = result.window;
    return true;
  }

  private isCurrentTerminalInputTarget(payload: Record<string, unknown>): boolean {
    const surfaceId = payload.surfaceId;
    const layoutRevision = payload.layoutRevision;
    if (typeof surfaceId !== "string" || typeof layoutRevision !== "number") return false;
    return this.ctx.getWebSockets().some((socket) => {
      const host = socketAttachment(socket);
      return host?.role === "host" && host.sharedLayoutRevision === layoutRevision &&
        host.sharedTerminalSurfaceIds?.includes(surfaceId) === true;
    });
  }

  private consumeHostBroadcast(now: number): boolean {
    const result = consumeEventBudget(this.hostBroadcastWindow, HOST_BROADCAST_EVENTS_PER_SECOND, now);
    if (!result.ok) return false;
    this.hostBroadcastWindow = result.window;
    return true;
  }

  private nextServerSeq(): number {
    this.serverSeq = Math.max(this.serverSeq + 1, Date.now() * 1_000);
    return this.serverSeq;
  }

  private async hostIsWithinGrace(): Promise<boolean> {
    if (this.hostAvailabilityDeadline === null) return true;
    if (this.hostAvailabilityDeadline === undefined) {
      const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
      if (!metadata || metadata.status !== "active") return false;
      this.hostAvailabilityDeadline = hostIsUnavailable(metadata) ? hostReconnectDeadline(metadata) : null;
    }
    return this.hostAvailabilityDeadline === null || this.hostAvailabilityDeadline > Date.now();
  }

  private async endRoom(reason: "expired" | "host_ended"): Promise<void> {
    this.hostAvailabilityDeadline = undefined;
    const metadata = await this.ctx.storage.get<ShareRoomMetadata>(META_KEY);
    if (metadata) await this.ctx.storage.put(META_KEY, { ...metadata, status: "ended" });
    const endedFrame = this.encodeFrame("share.ended", { reason });
    for (const socket of this.ctx.getWebSockets()) {
      if (endedFrame) this.sendEncoded(socket, endedFrame);
      closeSocket(socket, 4000, reason);
    }
    await this.ctx.storage.deleteAll();
    if (metadata) {
      try {
        const ownerIndex = this.env.SHARE_OWNER_INDEX.get(
          this.env.SHARE_OWNER_INDEX.idFromName(metadata.owner.userId),
        );
        await ownerIndex.release(metadata.shareId);
      } catch {
        // Local collaboration data is already gone. The quota slot self-prunes
        // at room expiry if cross-object cleanup is temporarily unavailable.
      }
    }
  }
}

function socketAttachment(socket: WebSocket): SocketAttachment | null {
  try {
    return socket.deserializeAttachment() as SocketAttachment | null;
  } catch {
    return null;
  }
}

function persistAttachment(socket: WebSocket, attachment: SocketAttachment): void {
  try {
    socket.serializeAttachment(attachment);
  } catch {
    // A socket can close between validation and attachment persistence.
  }
}

function participantFrom(attachment: SocketAttachment): Participant {
  return {
    connectionId: attachment.connectionId,
    userId: attachment.userId,
    displayName: attachment.displayName,
    color: attachment.color,
    role: attachment.role,
  };
}

function decodePrincipal(value: string | null): Principal | null {
  if (!value || value.length > 4_096 || !/^[A-Za-z0-9_-]+$/.test(value)) return null;
  try {
    const padding = "=".repeat((4 - value.length % 4) % 4);
    const decoded = atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
    const bytes = Uint8Array.from(decoded, (character) => character.charCodeAt(0));
    const candidate = JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
    const userId = shortString(candidate.userId, 256);
    const email = shortString(candidate.email, 320);
    const displayName = shortString(candidate.displayName, 256);
    const nonceHash = candidate.nonceHash === undefined ? undefined : shortString(candidate.nonceHash, 64);
    const ticketExpiresAtString = candidate.ticketExpiresAt === undefined
      ? undefined
      : shortString(candidate.ticketExpiresAt, 32);
    const ticketExpiresAt = ticketExpiresAtString === undefined ? undefined : Number(ticketExpiresAtString);
    return userId && email && displayName && nonceHash !== null && ticketExpiresAtString !== null &&
      (ticketExpiresAt === undefined || (Number.isSafeInteger(ticketExpiresAt) && ticketExpiresAt > 0))
      ? {
          userId,
          email,
          displayName,
          ...(nonceHash ? { nonceHash } : {}),
          ...(ticketExpiresAt !== undefined ? { ticketExpiresAt } : {}),
        }
      : null;
  } catch {
    return null;
  }
}

function shortString(value: unknown, max: number): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= max ? value : null;
}

function websocketPair(): { client: WebSocket; server: WebSocket } {
  const pair = new WebSocketPair();
  return { client: pair[0], server: pair[1] };
}

function websocketResponse(client: WebSocket): Response {
  return new Response(null, {
    status: 101,
    webSocket: client,
    headers: { "sec-websocket-protocol": SHARE_WEBSOCKET_PROTOCOL },
  });
}

function closeSocket(socket: WebSocket, code: number, reason: string): void {
  try {
    socket.close(code, reason);
  } catch {
    // Already closed.
  }
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
