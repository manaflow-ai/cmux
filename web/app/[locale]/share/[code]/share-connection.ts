// ShareClient: the framework-free browser runtime for one terminal-only
// multiplayer session. React subscribes to session/cursor stores, while each
// terminal canvas subscribes directly to its bounded grid model.

import type {
  ChatMessage,
  CursorPos,
  GuestMessage,
  LayoutNode,
  Participant,
  Role,
  ServerMessage,
  SharedWorkspace,
  WorkspaceLayout,
} from "./share-protocol";
import {
  BINARY_KIND_GRID,
  decodeBinaryFrame,
  MAX_BINARY_MESSAGE_BYTES,
  MAX_CHAT_HISTORY,
  MAX_CHAT_TEXT_BYTES,
  MAX_CURSORS,
  MAX_LAYOUT_PANES,
  MAX_SERVER_MESSAGE_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  MAX_TERMINAL_PANES,
  normalizeServerMessage,
  PROTO_VERSION,
  truncateUtf8,
  utf8ByteLength,
  wireId,
} from "./share-protocol";
import { TerminalGridModel } from "./terminal-grid";

type DomainServerMessage = Exclude<ServerMessage, { t: "ack-request" }>;

interface DeferredOutboundBatch {
  socket: WebSocket;
  messages: GuestMessage[];
}

export type ShareStatus =
  | "connecting"
  | "pending"
  | "denied"
  | "kicked"
  | "active"
  | "ended"
  | "unavailable";

export interface ShareSessionState {
  status: ShareStatus;
  endedReason: "host-stopped" | "host-gone" | "expired" | null;
  /** Array-shaped for v1 wire compatibility, but always zero or one item. */
  shared: SharedWorkspace[];
  /** Contains only the layout matching `shared[0]`. */
  layouts: Record<string, WorkspaceLayout>;
  participants: Participant[];
  chat: ChatMessage[];
  you: { user: string; role: Role; color: number; isHost: boolean } | null;
  /** The single server-selected shared workspace. */
  activeWs: string | null;
  reconnecting: boolean;
}

const INITIAL_STATE: ShareSessionState = {
  status: "connecting",
  endedReason: null,
  shared: [],
  layouts: {},
  participants: [],
  chat: [],
  you: null,
  activeWs: null,
  reconnecting: false,
};

type Listener = () => void;

class Store<T> {
  private listeners = new Set<Listener>();

  constructor(private value: T) {}

  get(): T {
    return this.value;
  }

  set(next: T): void {
    this.value = next;
    for (const listener of this.listeners) listener();
  }

  update(patch: Partial<T>): void {
    this.set({ ...this.value, ...patch });
  }

  subscribe = (listener: Listener): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
}

export interface RemoteCursor {
  user: string;
  pos: CursorPos | null;
  bubble?: { text: string; until: number };
}

const PANE_KEY_SEPARATOR = "\u0000";
const paneKey = (ws: string, pane: string) => `${ws}${PANE_KEY_SEPARATOR}${pane}`;
const splitPaneKey = (key: string): [string, string] | null => {
  const separator = key.indexOf(PANE_KEY_SEPARATOR);
  return separator > 0
    ? [key.slice(0, separator), key.slice(separator + PANE_KEY_SEPARATOR.length)]
    : null;
};

const CURSOR_SEND_INTERVAL_MS = 33;
const BUBBLE_VISIBLE_MS = 5_000;
const RECONNECT_BASE_MS = 800;
const RECONNECT_MAX_MS = 10_000;
const RETRY_AFTER_MIN_SECONDS = 1;
const RETRY_AFTER_MAX_SECONDS = 3_600;
const MAX_TOKEN_RESPONSE_CHARS = 64 * 1024;
const MAX_BEARER_TOKEN_BYTES = 8 * 1024;
const TERMINAL_PROTOCOL_CLOSE_CODES = new Set([1002, 1008, 1009, 4400]);
const TERMINAL_INVARIANT_CLOSE_REASONS = new Set([
  "delivery_failed",
  "server_message_too_large",
]);

function isTerminalStatus(status: ShareStatus): boolean {
  return status === "denied" || status === "kicked" || status === "ended" || status === "unavailable";
}

function isUnavailableClose(event: Pick<CloseEvent, "code" | "reason">): boolean {
  if (TERMINAL_PROTOCOL_CLOSE_CODES.has(event.code)) return true;
  // Reasons may select only this UX-neutral state. Authentication decisions
  // always require an authoritative close code or server message.
  return event.code === 1011 && TERMINAL_INVARIANT_CLOSE_REASONS.has(event.reason);
}

function selectedLayouts(
  workspace: SharedWorkspace | undefined,
  layouts: readonly WorkspaceLayout[],
): Record<string, WorkspaceLayout> {
  if (!workspace) return {};
  const layout = layouts.find((candidate) => candidate.ws === workspace.id);
  return layout ? { [workspace.id]: layout } : {};
}

function collectPaneKeys(
  ws: string,
  node: LayoutNode | null | undefined,
  content?: "terminal",
): Set<string> {
  const result = new Set<string>();
  if (!node) return result;
  const limit = content === "terminal" ? MAX_TERMINAL_PANES : MAX_LAYOUT_PANES;
  const stack: LayoutNode[] = [node];
  while (stack.length > 0 && result.size < limit) {
    const current = stack.pop();
    if (!current) continue;
    if (current.kind === "split") {
      stack.push(current.b, current.a);
    } else if (content === undefined || current.content === content) {
      result.add(paneKey(ws, current.pane));
    }
  }
  return result;
}

export function normalizeOutboundCursor(
  pos: CursorPos,
  activeWs: string | null,
): CursorPos | null {
  if (
    !activeWs ||
    pos.ws !== activeWs ||
    !wireId(pos.pane) ||
    !Number.isFinite(pos.x) ||
    !Number.isFinite(pos.y)
  ) {
    return null;
  }
  return {
    ws: activeWs,
    pane: pos.pane,
    x: Math.min(1, Math.max(0, pos.x)),
    y: Math.min(1, Math.max(0, pos.y)),
  };
}

async function jsonRecord(response: Response): Promise<Record<string, unknown> | null> {
  const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.includes("json")) return null;
  try {
    const text = await response.text();
    if (
      text.length > MAX_TOKEN_RESPONSE_CHARS ||
      utf8ByteLength(text) > MAX_TOKEN_RESPONSE_CHARS
    ) {
      return null;
    }
    const value = JSON.parse(text) as unknown;
    return value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function retryAfterMilliseconds(value: string | null, now = Date.now()): number | null {
  if (!value) return null;
  const trimmed = value.trim();
  let seconds: number;
  if (/^\d+(?:\.\d+)?$/u.test(trimmed)) {
    seconds = Number(trimmed);
  } else {
    const at = Date.parse(trimmed);
    if (!Number.isFinite(at)) return null;
    seconds = Math.ceil((at - now) / 1_000);
  }
  if (!Number.isFinite(seconds)) return null;
  return (
    Math.min(RETRY_AFTER_MAX_SECONDS, Math.max(RETRY_AFTER_MIN_SECONDS, Math.ceil(seconds))) *
    1_000
  );
}

function tokenGrant(
  body: Record<string, unknown> | null,
): { token: string; wsUrl: string } | null {
  if (
    !body ||
    typeof body.token !== "string" ||
    body.token.length === 0 ||
    body.token.length > MAX_BEARER_TOKEN_BYTES ||
    utf8ByteLength(body.token) > MAX_BEARER_TOKEN_BYTES ||
    typeof body.wsUrl !== "string" ||
    body.wsUrl.length > 4_096
  ) {
    return null;
  }
  try {
    const url = new URL(body.wsUrl);
    if (url.protocol === "wss:") return { token: body.token, wsUrl: body.wsUrl };
    if (url.protocol !== "ws:") return null;
    const hostname = url.hostname;
    const loopback =
      hostname === "localhost" ||
      hostname === "[::1]" ||
      /^127(?:\.\d{1,3}){3}$/u.test(hostname);
    if (!loopback) return null;
  } catch {
    return null;
  }
  return { token: body.token, wsUrl: body.wsUrl };
}

export class ShareClient {
  readonly session = new Store<ShareSessionState>(INITIAL_STATE);
  readonly cursors = new Store<ReadonlyMap<string, RemoteCursor>>(new Map());

  private ws: WebSocket | null = null;
  private tokenAbort: AbortController | null = null;
  private grids = new Map<string, TerminalGridModel>();
  private gridListeners = new Map<string, Set<Listener>>();
  private subs = new Set<string>();
  private stopped = true;
  private connectionGeneration = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pendingCursorResolver: (() => CursorPos | null) | undefined;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
  private bubbleTimer: ReturnType<typeof setTimeout> | null = null;
  private acceptingPayload: DeferredOutboundBatch | null = null;
  private pendingPayload: DeferredOutboundBatch | null = null;

  constructor(private readonly code: string) {}

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.beginConnect();
  }

  stop(): void {
    this.stopped = true;
    this.connectionGeneration += 1;
    this.tokenAbort?.abort();
    this.tokenAbort = null;
    if (this.reconnectTimer !== null) clearTimeout(this.reconnectTimer);
    if (this.cursorTimer !== null) clearTimeout(this.cursorTimer);
    if (this.bubbleTimer !== null) clearTimeout(this.bubbleTimer);
    this.reconnectTimer = null;
    this.cursorTimer = null;
    this.bubbleTimer = null;
    this.acceptingPayload = null;
    this.pendingPayload = null;
    this.pendingCursorResolver = undefined;
    this.reconnectAttempt = 0;
    const socket = this.ws;
    this.ws = null;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onclose = null;
      try {
        socket.close(1000, "leaving");
      } catch {
        // A malformed/partially constructed browser socket is already inert.
      }
    }
    this.subs.clear();
    this.grids.clear();
    this.gridListeners.clear();
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle

  private beginConnect(): void {
    if (this.stopped || this.tokenAbort || this.ws || isTerminalStatus(this.session.get().status)) {
      return;
    }
    const generation = this.connectionGeneration + 1;
    this.connectionGeneration = generation;
    void this.connect(generation);
  }

  private isCurrent(generation: number): boolean {
    return !this.stopped && this.connectionGeneration === generation;
  }

  private async connect(generation: number): Promise<void> {
    const controller = new AbortController();
    this.tokenAbort = controller;
    let response: Response;
    try {
      response = await fetch(`/api/share/sessions/${this.code}/token`, {
        method: "POST",
        signal: controller.signal,
      });
    } catch {
      if (this.tokenAbort === controller) this.tokenAbort = null;
      if (this.isCurrent(generation)) this.scheduleReconnect();
      return;
    }
    if (!this.isCurrent(generation)) return;

    if (!response.ok) {
      const body = await jsonRecord(response);
      if (this.tokenAbort === controller) this.tokenAbort = null;
      if (!this.isCurrent(generation)) return;
      const error = typeof body?.error === "string" ? body.error : null;
      if (
        error === "invalid_code" ||
        error === "share_not_configured" ||
        response.status === 401 ||
        response.status === 403 ||
        response.status === 404
      ) {
        this.markUnavailable();
        return;
      }
      if (response.status === 429) {
        this.scheduleReconnect(retryAfterMilliseconds(response.headers.get("retry-after")));
        return;
      }
      if (response.status >= 500 && response.status <= 599) {
        this.scheduleReconnect();
        return;
      }
      this.markUnavailable();
      return;
    }

    const grant = tokenGrant(await jsonRecord(response));
    if (this.tokenAbort === controller) this.tokenAbort = null;
    if (!this.isCurrent(generation)) return;
    if (!grant) {
      this.scheduleReconnect();
      return;
    }

    let socket: WebSocket;
    try {
      const url = new URL(grant.wsUrl);
      url.searchParams.set("token", grant.token);
      socket = new WebSocket(url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    if (!this.isCurrent(generation)) {
      try {
        socket.close(1000, "stale connection");
      } catch {
        // The stale socket is already unusable.
      }
      return;
    }
    socket.binaryType = "arraybuffer";
    this.ws = socket;
    socket.onopen = () => {
      if (!this.isCurrentSocket(socket, generation)) return;
      this.send({ t: "hello", proto: PROTO_VERSION });
    };
    const dropPendingPayload = (): void => {
      if (this.pendingPayload?.socket === socket) this.pendingPayload = null;
      if (this.acceptingPayload?.socket === socket) this.acceptingPayload = null;
    };
    const acceptPayload = (handler: () => boolean): void => {
      dropPendingPayload();
      const batch: DeferredOutboundBatch = { socket, messages: [] };
      this.acceptingPayload = batch;
      let accepted = false;
      try {
        accepted = handler();
      } finally {
        if (this.acceptingPayload === batch) this.acceptingPayload = null;
      }
      if (accepted && this.isCurrentSocket(socket, generation)) {
        this.pendingPayload = batch;
      }
    };
    const closeLocallyUnavailable = (reason: string): void => {
      dropPendingPayload();
      this.markUnavailable();
      try {
        socket.close(1009, reason);
      } catch {
        // The socket is already unusable; stop() still owns final cleanup.
      }
    };
    const receiveBinary = (data: Uint8Array): void => {
      if (data.byteLength >= MAX_BINARY_MESSAGE_BYTES) {
        closeLocallyUnavailable("binary message too large");
        return;
      }
      acceptPayload(() => this.handleBinary(data));
    };
    socket.onmessage = (event) => {
      if (!this.isCurrentSocket(socket, generation)) return;
      try {
        if (typeof event.data === "string") {
          if (
            event.data.length >= MAX_SERVER_MESSAGE_BYTES ||
            utf8ByteLength(event.data) >= MAX_SERVER_MESSAGE_BYTES
          ) {
            closeLocallyUnavailable("message too large");
            return;
          }
          const message = normalizeServerMessage(JSON.parse(event.data) as unknown);
          if (message?.t === "ack-request") {
            const pending =
              this.pendingPayload?.socket === socket ? this.pendingPayload : null;
            dropPendingPayload();
            if (
              pending &&
              this.sendImmediate({ t: "ack", nonce: message.nonce })
            ) {
              for (const deferred of pending.messages) {
                if (!this.sendImmediate(deferred)) break;
              }
            }
            return;
          }
          if (!message) {
            dropPendingPayload();
            return;
          }
          acceptPayload(() => {
            this.handleServerMessage(message);
            return true;
          });
          return;
        }
        if (event.data instanceof ArrayBuffer) {
          receiveBinary(new Uint8Array(event.data));
          return;
        }
        if (ArrayBuffer.isView(event.data)) {
          receiveBinary(
            new Uint8Array(event.data.buffer, event.data.byteOffset, event.data.byteLength),
          );
          return;
        }
        dropPendingPayload();
      } catch {
        dropPendingPayload();
        // Untrusted JSON/binary data never escapes the socket boundary.
      }
    };
    socket.onclose = (event) => {
      if (!this.isCurrentSocket(socket, generation)) return;
      dropPendingPayload();
      this.ws = null;
      // A replacement socket has no server-side subscription state. Preserve
      // local grids/layout, then rebuild desired subscriptions from snapshot.
      this.subs.clear();
      const status = this.session.get().status;
      if (this.stopped || isTerminalStatus(status)) return;
      if (event.code === 4003) {
        this.enterStateWithoutSessionData("denied");
        return;
      }
      if (isUnavailableClose(event)) {
        this.markUnavailable();
        return;
      }
      this.scheduleReconnect();
    };
  }

  private isCurrentSocket(socket: WebSocket, generation: number): boolean {
    return this.isCurrent(generation) && this.ws === socket;
  }

  private scheduleReconnect(requestedDelay: number | null = null): void {
    const status = this.session.get().status;
    if (
      this.stopped ||
      isTerminalStatus(status) ||
      this.reconnectTimer !== null ||
      this.tokenAbort !== null ||
      this.ws !== null
    ) {
      return;
    }
    if (this.cursorTimer !== null) clearTimeout(this.cursorTimer);
    this.cursorTimer = null;
    this.pendingCursorResolver = undefined;
    this.session.update({ reconnecting: true });
    const delay =
      requestedDelay ??
      Math.min(RECONNECT_MAX_MS, RECONNECT_BASE_MS * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.beginConnect();
    }, delay);
  }

  private markUnavailable(): void {
    this.enterStateWithoutSessionData("unavailable");
  }

  /** Re-send focus/subs after reconnect or a Durable Object resync. */
  private replayVolatileState(): void {
    const { activeWs } = this.session.get();
    this.send({ t: "focus", ws: activeWs });
    for (const key of this.subs) {
      const parts = splitPaneKey(key);
      if (parts) this.send({ t: "sub", ws: parts[0], pane: parts[1] });
    }
  }

  // -------------------------------------------------------------------------
  // Inbound

  private handleServerMessage(message: DomainServerMessage): void {
    switch (message.t) {
      case "session-state": {
        const workspace = message.shared[0];
        const layouts = selectedLayouts(workspace, message.layouts);
        const activeWs = workspace?.id ?? null;
        this.session.set({
          status: "active",
          reconnecting: false,
          endedReason: null,
          shared: workspace ? [workspace] : [],
          layouts,
          participants: message.participants,
          chat: message.chat.slice(-MAX_CHAT_HISTORY),
          you: message.you,
          activeWs,
        });
        this.pruneCursors(message.participants);
        this.syncWorkspaceSubscriptions(activeWs);
        this.send({ t: "focus", ws: activeWs });
        this.reconnectAttempt = 0;
        break;
      }
      case "access-pending":
        this.enterStateWithoutSessionData("pending");
        break;
      case "access-denied":
        this.enterStateWithoutSessionData("denied");
        break;
      case "kicked":
        this.enterStateWithoutSessionData("kicked");
        break;
      case "presence":
        this.session.update({ participants: message.participants });
        this.pruneCursors(message.participants);
        break;
      case "shared": {
        const workspace = message.shared[0];
        const current = this.session.get();
        const activeWs = workspace?.id ?? null;
        this.session.update({
          shared: workspace ? [workspace] : [],
          activeWs,
          layouts:
            activeWs && current.layouts[activeWs]
              ? { [activeWs]: current.layouts[activeWs] }
              : {},
        });
        this.syncWorkspaceSubscriptions(activeWs);
        this.send({ t: "focus", ws: activeWs });
        break;
      }
      case "layout": {
        const activeWs = this.session.get().activeWs;
        if (message.layout.ws !== activeWs) break;
        this.session.update({ layouts: { [message.layout.ws]: message.layout } });
        this.syncWorkspaceSubscriptions(activeWs);
        break;
      }
      case "cursor": {
        const next = new Map(this.cursors.get());
        const existing = next.get(message.user);
        if (existing) next.delete(message.user);
        next.set(message.user, {
          user: message.user,
          pos: message.pos,
          ...(existing?.bubble ? { bubble: existing.bubble } : {}),
        });
        while (next.size > MAX_CURSORS) {
          const oldest = next.keys().next().value as string | undefined;
          if (!oldest) break;
          next.delete(oldest);
        }
        this.cursors.set(next);
        break;
      }
      case "chat": {
        const chat = [...this.session.get().chat, message.msg].slice(-MAX_CHAT_HISTORY);
        this.session.update({ chat });
        if (message.msg.bubble) this.showBubble(message.msg);
        break;
      }
      case "role-changed": {
        const you = this.session.get().you;
        if (you) this.session.update({ you: { ...you, role: message.role } });
        break;
      }
      case "resync":
        this.replayVolatileState();
        break;
      case "session-ended":
        this.enterStateWithoutSessionData("ended", message.reason);
        break;
      case "access-request":
      case "error":
        break;
    }
  }

  private enterStateWithoutSessionData(
    status: "pending" | "denied" | "kicked" | "ended" | "unavailable",
    endedReason: ShareSessionState["endedReason"] = null,
  ): void {
    if (this.reconnectTimer !== null) clearTimeout(this.reconnectTimer);
    if (this.cursorTimer !== null) clearTimeout(this.cursorTimer);
    if (this.bubbleTimer !== null) clearTimeout(this.bubbleTimer);
    this.reconnectTimer = null;
    this.cursorTimer = null;
    this.bubbleTimer = null;
    this.pendingCursorResolver = undefined;
    this.subs.clear();
    this.grids.clear();
    this.gridListeners.clear();
    this.session.set({
      ...INITIAL_STATE,
      status,
      endedReason,
      reconnecting: false,
    });
    this.cursors.set(new Map());
  }

  private handleBinary(data: Uint8Array): boolean {
    const frame = decodeBinaryFrame(data);
    if (!frame || frame.kind !== BINARY_KIND_GRID) return false;
    const key = paneKey(frame.ws, frame.pane);
    if (!this.subs.has(key)) return false;
    const model = this.gridFor(frame.ws, frame.pane);
    let parsed: unknown;
    try {
      parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(frame.payload));
    } catch {
      return false;
    }
    if (!model.apply(parsed)) return false;
    const listeners = this.gridListeners.get(key);
    if (listeners) {
      for (const listener of listeners) listener();
    }
    return true;
  }

  private showBubble(message: ChatMessage): void {
    const next = new Map(this.cursors.get());
    const existing = next.get(message.user);
    if (existing) next.delete(message.user);
    next.set(message.user, {
      user: message.user,
      pos: existing?.pos ?? message.bubble ?? null,
      bubble: {
        text: truncateUtf8(message.text, MAX_CHAT_TEXT_BYTES),
        until: Date.now() + BUBBLE_VISIBLE_MS,
      },
    });
    while (next.size > MAX_CURSORS) {
      const oldest = next.keys().next().value as string | undefined;
      if (!oldest) break;
      next.delete(oldest);
    }
    this.cursors.set(next);
    this.scheduleBubbleExpiry();
  }

  private scheduleBubbleExpiry(): void {
    if (this.bubbleTimer !== null) clearTimeout(this.bubbleTimer);
    this.bubbleTimer = null;
    let earliest = Number.POSITIVE_INFINITY;
    for (const cursor of this.cursors.get().values()) {
      if (cursor.bubble) earliest = Math.min(earliest, cursor.bubble.until);
    }
    if (!this.stopped && Number.isFinite(earliest)) {
      this.bubbleTimer = setTimeout(
        () => this.expireBubbles(),
        Math.max(1, earliest - Date.now() + 50),
      );
    }
  }

  private expireBubbles(): void {
    this.bubbleTimer = null;
    const now = Date.now();
    const next = new Map<string, RemoteCursor>();
    let changed = false;
    let nextExpiry = Number.POSITIVE_INFINITY;
    for (const [user, cursor] of this.cursors.get()) {
      if (cursor.bubble && cursor.bubble.until <= now) {
        next.set(user, { user: cursor.user, pos: cursor.pos });
        changed = true;
      } else {
        next.set(user, cursor);
        if (cursor.bubble) nextExpiry = Math.min(nextExpiry, cursor.bubble.until);
      }
    }
    if (changed) this.cursors.set(next);
    if (!this.stopped && Number.isFinite(nextExpiry)) this.scheduleBubbleExpiry();
  }

  private pruneCursors(participants: readonly Participant[]): void {
    const allowed = new Set(participants.map((participant) => participant.user));
    const next = new Map(
      [...this.cursors.get()].filter(([user]) => allowed.has(user)).slice(-MAX_CURSORS),
    );
    if (next.size !== this.cursors.get().size) this.cursors.set(next);
  }

  // -------------------------------------------------------------------------
  // Outbound

  private send(message: GuestMessage): boolean {
    const deferred =
      this.acceptingPayload?.socket === this.ws
        ? this.acceptingPayload
        : this.pendingPayload?.socket === this.ws
          ? this.pendingPayload
          : null;
    if (deferred && this.ws?.readyState === WebSocket.OPEN) {
      deferred.messages.push(message);
      return true;
    }
    return this.sendImmediate(message);
  }

  private sendImmediate(message: GuestMessage): boolean {
    if (this.ws?.readyState !== WebSocket.OPEN) return false;
    try {
      this.ws.send(JSON.stringify(message));
      return true;
    } catch {
      // Closing sockets can race an input event; onclose owns reconnect.
      return false;
    }
  }

  /** Subscribe only to terminal leaves in the one server-selected workspace. */
  private syncWorkspaceSubscriptions(ws: string | null): void {
    const layout = ws ? this.session.get().layouts[ws] : undefined;
    const wanted = ws ? collectPaneKeys(ws, layout?.tree, "terminal") : new Set<string>();
    for (const key of [...this.subs]) {
      if (wanted.has(key)) continue;
      const parts = splitPaneKey(key);
      if (parts) this.send({ t: "unsub", ws: parts[0], pane: parts[1] });
      this.subs.delete(key);
      this.grids.delete(key);
    }
    for (const key of wanted) {
      if (this.subs.has(key)) continue;
      const parts = splitPaneKey(key);
      if (parts) this.send({ t: "sub", ws: parts[0], pane: parts[1] });
      this.subs.add(key);
    }
    for (const key of [...this.grids.keys()]) {
      if (!wanted.has(key)) this.grids.delete(key);
    }
  }

  /** Throttled pane-relative cursor updates; `null` hides the cursor. */
  sendCursor(pos: CursorPos | null): void {
    this.sendCursorSample(() => pos);
  }

  /**
   * Throttles raw pointer samples and resolves pane geometry only for the
   * latest sample when its send slot becomes available.
   */
  sendCursorSample(resolve: () => CursorPos | null): void {
    const session = this.session.get();
    if (session.status !== "active" || session.reconnecting) return;
    this.pendingCursorResolver = resolve;
    if (this.cursorTimer !== null) return;
    this.cursorTimer = setTimeout(() => {
      this.cursorTimer = null;
      const resolver = this.pendingCursorResolver;
      this.pendingCursorResolver = undefined;
      if (!resolver) return;
      const current = this.session.get();
      if (current.status !== "active" || current.reconnecting) return;
      const candidate = resolver();
      if (candidate === null) {
        this.send({ t: "cursor", pos: null });
        return;
      }
      const normalized = normalizeOutboundCursor(candidate, current.activeWs);
      const layout = current.activeWs ? current.layouts[current.activeWs] : undefined;
      const allowed = current.activeWs
        ? collectPaneKeys(current.activeWs, layout?.tree)
        : new Set<string>();
      if (!normalized || !allowed.has(paneKey(normalized.ws, normalized.pane))) return;
      this.send({ t: "cursor", pos: normalized });
    }, CURSOR_SEND_INTERVAL_MS);
  }

  sendChat(text: string, bubble?: CursorPos): boolean {
    const session = this.session.get();
    if (session.status !== "active" || session.reconnecting || !session.you) {
      return false;
    }
    const trimmed = truncateUtf8(text.trim(), MAX_CHAT_TEXT_BYTES).trim();
    if (!trimmed) return false;
    const normalizedBubble = bubble
      ? normalizeOutboundCursor(bubble, session.activeWs)
      : null;
    const layout = session.activeWs ? session.layouts[session.activeWs] : undefined;
    const allowed = session.activeWs
      ? collectPaneKeys(session.activeWs, layout?.tree)
      : new Set<string>();
    const bubbleInLayout =
      normalizedBubble && allowed.has(paneKey(normalizedBubble.ws, normalizedBubble.pane))
        ? normalizedBubble
        : null;
    return this.send(
      bubbleInLayout
        ? { t: "chat", text: trimmed, bubble: bubbleInLayout }
        : { t: "chat", text: trimmed },
    );
  }

  sendInput(ws: string, pane: string, data: string): boolean {
    const session = this.session.get();
    if (
      session.status !== "active" ||
      session.reconnecting ||
      session.you?.role !== "editor" ||
      ws !== session.activeWs ||
      !this.subs.has(paneKey(ws, pane)) ||
      data.length === 0
    ) {
      return false;
    }
    return this.send({
      t: "input",
      ws,
      pane,
      data: truncateUtf8(data, MAX_TERMINAL_INPUT_BYTES),
    });
  }

  // -------------------------------------------------------------------------
  // Grid access for terminal canvases

  gridFor(ws: string, pane: string): TerminalGridModel {
    const key = paneKey(ws, pane);
    let model = this.grids.get(key);
    if (model) return model;
    while (this.grids.size >= MAX_TERMINAL_PANES) {
      const evictable = [...this.grids.keys()].find(
        (candidate) => !this.subs.has(candidate) && !this.gridListeners.has(candidate),
      );
      if (!evictable) return new TerminalGridModel();
      this.grids.delete(evictable);
    }
    model = new TerminalGridModel();
    this.grids.set(key, model);
    return model;
  }

  subscribeGrid(ws: string, pane: string, listener: Listener): () => void {
    const key = paneKey(ws, pane);
    let listeners = this.gridListeners.get(key);
    if (!listeners) {
      if (this.gridListeners.size >= MAX_LAYOUT_PANES) return () => {};
      listeners = new Set();
      this.gridListeners.set(key, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners?.delete(listener);
      if (listeners?.size === 0) this.gridListeners.delete(key);
    };
  }
}
