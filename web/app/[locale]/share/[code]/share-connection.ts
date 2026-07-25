// ShareClient: the framework-free browser runtime for one terminal-only
// multiplayer session. React subscribes to session/cursor stores, while each
// terminal pane binds an xterm parser directly to its sequenced PTY stream.

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
import {
  TerminalStreamCoordinator,
  type TerminalCompatibilityError,
} from "./terminal-stream";
import {
  decodeTerminalFrame,
  encodeTerminalInputFrame,
  terminalStreamFrame,
  TERMINAL_KIND_BASELINE,
  TERMINAL_KIND_OUTPUT,
  TERMINAL_TRANSPORT_VERSION,
} from "./terminal-wire";

type DomainServerMessage = Exclude<ServerMessage, { t: "ack-request" }>;

type OutboundPayload = GuestMessage | Uint8Array;

const MAX_PENDING_DELIVERY_BATCHES = 128;

interface DeferredOutboundBatch {
  socket: WebSocket;
  messages: OutboundPayload[];
  accepted: boolean;
  settled: boolean;
  nonce: string | null;
}

export interface ShareTerminalAdapter {
  resize(columns: number, rows: number): void;
  write(data: Uint8Array, onConsumed: () => void): void;
}

interface TerminalChannel {
  coordinator: TerminalStreamCoordinator;
  adapter: ShareTerminalAdapter | null;
  geometry: { columns: number; rows: number } | null;
  pendingWrite: { data: Uint8Array; onConsumed: () => void } | null;
  inFlightConsumed: (() => void) | null;
  needsResync: boolean;
}

interface QueuedTerminalInput {
  readonly ws: string;
  readonly pane: string;
  readonly data: Uint8Array;
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
  terminalError: TerminalCompatibilityError | null;
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
  terminalError: null,
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
const TERMINAL_INPUT_QUEUE_MAX_BYTES = 2 * 1024 * 1024;
const TERMINAL_INPUT_WINDOW_MS = 1_000;
const TERMINAL_INPUT_FRAMES_PER_WINDOW = 24;
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
):
  | {
      ok: true;
      token: string;
      wsUrl: string;
      deploymentId: string;
    }
  | {
      ok: false;
      error: TerminalCompatibilityError;
    }
  | null {
  if (
    !body ||
    typeof body.token !== "string" ||
    body.token.length === 0 ||
    body.token.length > MAX_BEARER_TOKEN_BYTES ||
    utf8ByteLength(body.token) > MAX_BEARER_TOKEN_BYTES ||
    typeof body.wsUrl !== "string" ||
    body.wsUrl.length > 4_096 ||
    typeof body.deploymentId !== "string" ||
    body.deploymentId.length === 0 ||
    body.deploymentId.length > 256 ||
    utf8ByteLength(body.deploymentId) > 256 ||
    /\p{Cc}/u.test(body.deploymentId)
  ) {
    return null;
  }
  if (body.protocolVersion !== PROTO_VERSION) {
    return {
      ok: false,
      error: {
        code: "protocol_version_mismatch",
        message: "protocol_version_mismatch",
      },
    };
  }
  if (body.terminalTransportVersion !== TERMINAL_TRANSPORT_VERSION) {
    return {
      ok: false,
      error: {
        code: "terminal_version_mismatch",
        message: "terminal_version_mismatch",
      },
    };
  }
  try {
    const url = new URL(body.wsUrl);
    if (url.protocol !== "wss:") {
      if (url.protocol !== "ws:") return null;
      const hostname = url.hostname;
      const loopback =
        hostname === "localhost" ||
        hostname === "[::1]" ||
        /^127(?:\.\d{1,3}){3}$/u.test(hostname);
      if (!loopback) return null;
    }
  } catch {
    return null;
  }
  return {
    ok: true,
    token: body.token,
    wsUrl: body.wsUrl,
    deploymentId: body.deploymentId,
  };
}

export class ShareClient {
  readonly session = new Store<ShareSessionState>(INITIAL_STATE);
  readonly cursors = new Store<ReadonlyMap<string, RemoteCursor>>(new Map());

  private ws: WebSocket | null = null;
  private tokenAbort: AbortController | null = null;
  private terminals = new Map<string, TerminalChannel>();
  private subs = new Set<string>();
  private stopped = true;
  private connectionGeneration = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pendingCursorResolver: (() => CursorPos | null) | undefined;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
  private bubbleTimer: ReturnType<typeof setTimeout> | null = null;
  private acceptingPayload: DeferredOutboundBatch | null = null;
  private pendingPayloads: DeferredOutboundBatch[] = [];
  private terminalInputQueue: QueuedTerminalInput[] = [];
  private terminalInputQueuedBytes = 0;
  private terminalInputWindowStartedAt = 0;
  private terminalInputFramesInWindow = 0;
  private terminalInputTimer: ReturnType<typeof setTimeout> | null = null;

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
    if (this.terminalInputTimer !== null) clearTimeout(this.terminalInputTimer);
    this.reconnectTimer = null;
    this.cursorTimer = null;
    this.bubbleTimer = null;
    this.terminalInputTimer = null;
    this.acceptingPayload = null;
    this.pendingPayloads = [];
    this.clearTerminalInputQueue();
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
    for (const channel of this.terminals.values()) {
      this.releaseTerminalChannel(channel);
    }
    this.terminals.clear();
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
    if (!grant.ok) {
      this.markCompatibilityError(grant.error);
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
    const dropUnmarkedPayload = (): void => {
      const pending = this.pendingPayloads.at(-1);
      if (pending?.socket === socket && pending.nonce === null) {
        this.pendingPayloads.pop();
      }
      if (this.acceptingPayload?.socket === socket) {
        this.acceptingPayload = null;
      }
    };
    const dropSocketPayloads = (): void => {
      this.pendingPayloads = this.pendingPayloads.filter(
        (batch) => batch.socket !== socket,
      );
      if (this.acceptingPayload?.socket === socket) {
        this.acceptingPayload = null;
      }
    };
    const closeLocallyUnavailable = (reason: string): void => {
      dropSocketPayloads();
      this.markUnavailable();
      try {
        socket.close(1009, reason);
      } catch {
        // The socket is already unusable; stop() still owns final cleanup.
      }
    };
    const flushPayloads = (): void => {
      while (this.isCurrentSocket(socket, generation)) {
        const batch = this.pendingPayloads[0];
        if (
          !batch ||
          batch.socket !== socket ||
          batch.nonce === null ||
          !batch.settled
        ) {
          return;
        }
        this.pendingPayloads.shift();
        if (!batch.accepted) continue;
        if (!this.sendImmediate({ t: "ack", nonce: batch.nonce })) return;
        for (const deferred of batch.messages) {
          if (!this.sendImmediate(deferred)) return;
        }
      }
    };
    const acceptPayload = (
      handler: () => boolean | Promise<boolean>,
    ): void => {
      // A second logical payload without the first payload's adjacent marker
      // violates the relay contract. Displace only that unmarked payload;
      // already-marked xterm writes retain their delivery credit.
      dropUnmarkedPayload();
      if (this.pendingPayloads.length >= MAX_PENDING_DELIVERY_BATCHES) {
        closeLocallyUnavailable("delivery window overflow");
        return;
      }
      const batch: DeferredOutboundBatch = {
        socket,
        messages: [],
        accepted: false,
        settled: false,
        nonce: null,
      };
      this.pendingPayloads.push(batch);
      this.acceptingPayload = batch;
      try {
        const accepted = handler();
        if (typeof accepted === "boolean") {
          batch.accepted = accepted;
          batch.settled = true;
        } else {
          void accepted.then(
            (value) => {
              batch.accepted = value;
              batch.settled = true;
              flushPayloads();
            },
            () => {
              batch.accepted = false;
              batch.settled = true;
              flushPayloads();
            },
          );
        }
      } catch {
        batch.accepted = false;
        batch.settled = true;
      } finally {
        if (this.acceptingPayload === batch) this.acceptingPayload = null;
      }
      if (!this.isCurrentSocket(socket, generation)) {
        dropSocketPayloads();
        return;
      }
      flushPayloads();
    };
    const acknowledgePayload = (
      batch: DeferredOutboundBatch,
      nonce: string,
    ): void => {
      if (batch.nonce !== null) return;
      batch.nonce = nonce;
      flushPayloads();
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
          const rawMessage = JSON.parse(event.data) as unknown;
          if (
            rawMessage !== null &&
            typeof rawMessage === "object" &&
            !Array.isArray(rawMessage) &&
            (rawMessage as { t?: unknown }).t === "session-state" &&
            (rawMessage as { proto?: unknown }).proto !== PROTO_VERSION
          ) {
            this.markCompatibilityError({
              code: "protocol_version_mismatch",
              message: "protocol_version_mismatch",
            });
            try {
              socket.close(4406, "unsupported protocol");
            } catch {
              // The compatibility state is already authoritative locally.
            }
            return;
          }
          const message = normalizeServerMessage(rawMessage);
          if (message?.t === "ack-request") {
            const pending =
              this.pendingPayloads.at(-1)?.socket === socket
                ? this.pendingPayloads.at(-1) ?? null
                : null;
            if (pending) acknowledgePayload(pending, message.nonce);
            return;
          }
          if (!message) {
            dropUnmarkedPayload();
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
        dropUnmarkedPayload();
      } catch {
        dropUnmarkedPayload();
        // Untrusted JSON/binary data never escapes the socket boundary.
      }
    };
    socket.onclose = (event) => {
      if (!this.isCurrentSocket(socket, generation)) return;
      dropSocketPayloads();
      this.ws = null;
      this.clearTerminalInputQueue();
      // A replacement socket has no server-side subscription state. Preserve
      // local xterm/layout state, then rebuild desired subscriptions.
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

  private markCompatibilityError(error: TerminalCompatibilityError): void {
    this.enterStateWithoutSessionData("unavailable", null, error);
  }

  /** Fail closed when the pinned xterm runtime contract cannot be installed. */
  reportTerminalRuntimeFailure(): void {
    this.markCompatibilityError({
      code: "terminal_runtime_mismatch",
      message: "terminal_runtime_mismatch",
    });
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
          terminalError: null,
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
        if (message.role !== "editor") this.clearTerminalInputQueue();
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
    terminalError: TerminalCompatibilityError | null = null,
  ): void {
    if (this.reconnectTimer !== null) clearTimeout(this.reconnectTimer);
    if (this.cursorTimer !== null) clearTimeout(this.cursorTimer);
    if (this.bubbleTimer !== null) clearTimeout(this.bubbleTimer);
    if (this.terminalInputTimer !== null) clearTimeout(this.terminalInputTimer);
    this.reconnectTimer = null;
    this.cursorTimer = null;
    this.bubbleTimer = null;
    this.terminalInputTimer = null;
    this.pendingCursorResolver = undefined;
    this.subs.clear();
    this.clearTerminalInputQueue();
    for (const channel of this.terminals.values()) {
      this.releaseTerminalChannel(channel);
    }
    this.terminals.clear();
    this.session.set({
      ...INITIAL_STATE,
      status,
      endedReason,
      reconnecting: false,
      terminalError,
    });
    this.cursors.set(new Map());
  }

  private async handleBinary(data: Uint8Array): Promise<boolean> {
    const frame = decodeTerminalFrame(data);
    if (
      !frame ||
      (frame.kind !== TERMINAL_KIND_BASELINE &&
        frame.kind !== TERMINAL_KIND_OUTPUT)
    ) {
      return false;
    }
    const key = paneKey(frame.ws, frame.pane);
    if (!this.subs.has(key)) return false;
    const channel = this.terminalChannelFor(frame.ws, frame.pane);
    if (
      frame.kind === TERMINAL_KIND_OUTPUT &&
      frame.rows > 0 &&
      frame.columns > 0 &&
      channel.geometry !== null &&
      (channel.geometry.rows !== frame.rows ||
        channel.geometry.columns !== frame.columns)
    ) {
      this.requestTerminalResync(frame.ws, frame.pane);
      return true;
    }
    const streamFrame = terminalStreamFrame(frame, PROTO_VERSION);
    if (!streamFrame) return false;
    await channel.coordinator.consume(streamFrame);
    if (channel.coordinator.terminalError) {
      this.markCompatibilityError(channel.coordinator.terminalError);
    }
    // A valid, authorized relay frame is transport-consumed even when its
    // sequence was rejected. In that case the deferred resync is sent
    // immediately after the ACK, releasing Durable Object delivery credit.
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
    return this.sendOutbound(message);
  }

  private sendOutbound(message: OutboundPayload): boolean {
    const pending = this.pendingPayloads.at(-1);
    const deferred =
      this.acceptingPayload?.socket === this.ws
        ? this.acceptingPayload
        : pending?.socket === this.ws
          ? pending
          : null;
    if (deferred && this.ws?.readyState === WebSocket.OPEN) {
      deferred.messages.push(message);
      return true;
    }
    return this.sendImmediate(message);
  }

  private sendImmediate(message: OutboundPayload): boolean {
    if (this.ws?.readyState !== WebSocket.OPEN) return false;
    try {
      if (message instanceof Uint8Array) {
        const bytes = new Uint8Array(message.byteLength);
        bytes.set(message);
        this.ws.send(bytes.buffer);
      } else {
        this.ws.send(JSON.stringify(message));
      }
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
      const channel = this.terminals.get(key);
      if (channel) this.releaseTerminalChannel(channel);
      this.terminals.delete(key);
    }
    for (const key of wanted) {
      if (this.subs.has(key)) continue;
      const parts = splitPaneKey(key);
      if (parts) this.send({ t: "sub", ws: parts[0], pane: parts[1] });
      this.subs.add(key);
    }
    for (const key of [...this.terminals.keys()]) {
      if (wanted.has(key)) continue;
      const channel = this.terminals.get(key);
      if (channel) this.releaseTerminalChannel(channel);
      this.terminals.delete(key);
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
  // xterm binding for terminal panes

  sendTerminalData(ws: string, pane: string, data: string): boolean {
    const key = paneKey(ws, pane);
    if (!this.subs.has(key)) return false;
    return this.terminalChannelFor(ws, pane).coordinator.onData(data);
  }

  sendTerminalBinary(ws: string, pane: string, data: string): boolean {
    const key = paneKey(ws, pane);
    if (!this.subs.has(key)) return false;
    return this.terminalChannelFor(ws, pane).coordinator.onBinary(data);
  }

  attachTerminal(
    ws: string,
    pane: string,
    adapter: ShareTerminalAdapter,
  ): () => void {
    const key = paneKey(ws, pane);
    if (!this.subs.has(key)) return () => {};
    const channel = this.terminalChannelFor(ws, pane);
    if (channel.adapter && channel.adapter !== adapter) {
      channel.needsResync = true;
    }
    channel.adapter = adapter;
    if (channel.geometry) {
      adapter.resize(channel.geometry.columns, channel.geometry.rows);
    }
    const pending = channel.pendingWrite;
    channel.pendingWrite = null;
    if (pending) this.writeToTerminal(channel, adapter, pending);
    if (channel.needsResync) {
      channel.needsResync = false;
      this.requestTerminalResync(ws, pane);
    }
    return () => {
      if (channel.adapter !== adapter) return;
      channel.adapter = null;
      channel.needsResync = true;
      const consumed = channel.inFlightConsumed;
      channel.inFlightConsumed = null;
      consumed?.();
    };
  }

  private terminalChannelFor(ws: string, pane: string): TerminalChannel {
    const key = paneKey(ws, pane);
    const existing = this.terminals.get(key);
    if (existing) return existing;
    let channel: TerminalChannel;
    const coordinator = new TerminalStreamCoordinator({
      protocolVersion: PROTO_VERSION,
      terminalVersion: TERMINAL_TRANSPORT_VERSION,
      resize: (columns, rows) => {
        channel.geometry = { columns, rows };
        channel.adapter?.resize(columns, rows);
      },
      write: (data, onConsumed) => {
        const pending = { data: data.slice(), onConsumed };
        const adapter = channel.adapter;
        if (adapter) {
          this.writeToTerminal(channel, adapter, pending);
        } else {
          channel.pendingWrite?.onConsumed();
          channel.pendingWrite = pending;
        }
      },
      onResyncRequested: () => {
        this.requestTerminalResync(ws, pane);
      },
      sendTerminalInput: ({ data }) =>
        this.sendTerminalInputBytes(ws, pane, data),
    });
    channel = {
      coordinator,
      adapter: null,
      geometry: null,
      pendingWrite: null,
      inFlightConsumed: null,
      needsResync: false,
    };
    while (this.terminals.size >= MAX_TERMINAL_PANES) {
      const evictable = [...this.terminals.entries()].find(
        ([candidate, value]) =>
          candidate !== key &&
          !this.subs.has(candidate) &&
          value.adapter === null,
      );
      if (!evictable) break;
      this.releaseTerminalChannel(evictable[1]);
      this.terminals.delete(evictable[0]);
    }
    this.terminals.set(key, channel);
    return channel;
  }

  private writeToTerminal(
    channel: TerminalChannel,
    adapter: ShareTerminalAdapter,
    write: { data: Uint8Array; onConsumed: () => void },
  ): void {
    channel.inFlightConsumed?.();
    let completed = false;
    const consumed = (): void => {
      if (completed) return;
      completed = true;
      if (channel.inFlightConsumed === consumed) {
        channel.inFlightConsumed = null;
      }
      write.onConsumed();
    };
    channel.inFlightConsumed = consumed;
    try {
      adapter.write(write.data, consumed);
    } catch {
      consumed();
      channel.needsResync = true;
    }
  }

  private releaseTerminalChannel(channel: TerminalChannel): void {
    channel.pendingWrite?.onConsumed();
    channel.pendingWrite = null;
    channel.inFlightConsumed?.();
    channel.inFlightConsumed = null;
    channel.adapter = null;
  }

  private requestTerminalResync(ws: string, pane: string): boolean {
    const session = this.session.get();
    if (
      session.status !== "active" ||
      session.reconnecting ||
      ws !== session.activeWs ||
      !this.subs.has(paneKey(ws, pane))
    ) {
      return false;
    }
    return this.send({ t: "terminal-resync", ws, pane });
  }

  private sendTerminalInputBytes(
    ws: string,
    pane: string,
    data: Uint8Array,
  ): boolean {
    const session = this.session.get();
    if (
      session.status !== "active" ||
      session.reconnecting ||
      session.you?.role !== "editor" ||
      ws !== session.activeWs ||
      !this.subs.has(paneKey(ws, pane)) ||
      data.byteLength === 0
    ) {
      return false;
    }
    if (
      data.byteLength >
      TERMINAL_INPUT_QUEUE_MAX_BYTES - this.terminalInputQueuedBytes
    ) {
      return false;
    }
    for (
      let offset = 0;
      offset < data.byteLength;
      offset += MAX_TERMINAL_INPUT_BYTES
    ) {
      const end = Math.min(
        data.byteLength,
        offset + MAX_TERMINAL_INPUT_BYTES,
      );
      const chunk = data.slice(offset, end);
      this.terminalInputQueue.push({ ws, pane, data: chunk });
      this.terminalInputQueuedBytes += chunk.byteLength;
    }
    return this.drainTerminalInputQueue();
  }

  /**
   * Preserve large xterm pastes without exceeding the relay's one-second
   * ingress budget. Frame boundaries do not alter the opaque PTY byte stream.
   */
  private drainTerminalInputQueue(): boolean {
    if (this.terminalInputTimer !== null) {
      clearTimeout(this.terminalInputTimer);
      this.terminalInputTimer = null;
    }
    const now = Date.now();
    if (
      now < this.terminalInputWindowStartedAt ||
      now >= this.terminalInputWindowStartedAt + TERMINAL_INPUT_WINDOW_MS
    ) {
      this.terminalInputWindowStartedAt = now;
      this.terminalInputFramesInWindow = 0;
    }

    while (
      this.terminalInputFramesInWindow < TERMINAL_INPUT_FRAMES_PER_WINDOW
    ) {
      const next = this.terminalInputQueue[0];
      if (!next) return true;
      const current = this.session.get();
      if (
        current.status !== "active" ||
        current.reconnecting ||
        current.you?.role !== "editor" ||
        next.ws !== current.activeWs ||
        !this.subs.has(paneKey(next.ws, next.pane))
      ) {
        this.clearTerminalInputQueue();
        return false;
      }
      const frame = encodeTerminalInputFrame(
        next.ws,
        next.pane,
        next.data,
      );
      if (!frame || !this.sendOutbound(frame)) {
        this.clearTerminalInputQueue();
        return false;
      }
      this.terminalInputQueue.shift();
      this.terminalInputQueuedBytes -= next.data.byteLength;
      this.terminalInputFramesInWindow += 1;
    }

    if (this.terminalInputQueue.length > 0) {
      const delay = Math.max(
        1,
        this.terminalInputWindowStartedAt + TERMINAL_INPUT_WINDOW_MS - now,
      );
      this.terminalInputTimer = setTimeout(() => {
        this.terminalInputTimer = null;
        this.drainTerminalInputQueue();
      }, delay);
    }
    return true;
  }

  private clearTerminalInputQueue(): void {
    if (this.terminalInputTimer !== null) {
      clearTimeout(this.terminalInputTimer);
      this.terminalInputTimer = null;
    }
    this.terminalInputQueue = [];
    this.terminalInputQueuedBytes = 0;
    this.terminalInputWindowStartedAt = 0;
    this.terminalInputFramesInWindow = 0;
  }
}
