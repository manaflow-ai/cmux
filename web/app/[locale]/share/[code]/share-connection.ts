// ShareClient: the whole client runtime for one share session, framework-free.
//
// React subscribes through three narrow stores so update frequency stays
// proportional to what re-renders: session state (rare), cursors (~30 Hz,
// isolated to the cursor layer), and per-pane grid generations (painted
// imperatively onto canvases, never through React state).

import { PixelPaneModel } from "./pixel-pane";
import type {
  ChatMessage,
  ComposeCaret,
  ComposeOp,
  CursorPos,
  GuestMessage,
  LayoutNode,
  Participant,
  RenderGridFrame,
  Role,
  ServerMessage,
  SharedWorkspace,
  WorkspaceLayout,
} from "./share-protocol";
import {
  BINARY_KIND_GRID,
  BINARY_KIND_PIXEL,
  decodeBinaryFrame,
  PROTO_VERSION,
} from "./share-protocol";
import { TerminalGridModel } from "./terminal-grid";

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
  shared: SharedWorkspace[];
  layouts: Record<string, WorkspaceLayout>;
  participants: Participant[];
  chat: ChatMessage[];
  you: { user: string; role: Role; color: number; isHost: boolean } | null;
  /** Workspace this client is viewing. */
  activeWs: string | null;
  followUser: string | null;
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
  followUser: null,
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
    for (const l of this.listeners) l();
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
  /** Bubble text shown next to the cursor, with its expiry. */
  bubble?: { text: string; until: number };
}

const paneKey = (ws: string, pane: string) => `${ws} ${pane}`;
const CURSOR_SEND_INTERVAL_MS = 33;
const BUBBLE_VISIBLE_MS = 5_000;
const RECONNECT_BASE_MS = 800;
const RECONNECT_MAX_MS = 10_000;

export interface ComposeState {
  rev: number;
  text: string;
  carets: ComposeCaret[];
}

export class ShareClient {
  readonly session = new Store<ShareSessionState>(INITIAL_STATE);
  readonly cursors = new Store<ReadonlyMap<string, RemoteCursor>>(new Map());
  /** Authoritative composer state per field (agent pane id). */
  readonly compose = new Store<ReadonlyMap<string, ComposeState>>(new Map());

  private ws: WebSocket | null = null;
  private grids = new Map<string, TerminalGridModel>();
  private gridListeners = new Map<string, Set<Listener>>();
  private pixels = new Map<string, PixelPaneModel>();
  private subs = new Set<string>();
  private stopped = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pendingCursor: CursorPos | null | undefined;
  private cursorTimer: ReturnType<typeof setTimeout> | null = null;
  private lastPointerMoveSent = 0;
  private bubbleTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly code: string) {}

  start(): void {
    this.stopped = false;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.cursorTimer) clearTimeout(this.cursorTimer);
    if (this.bubbleTimer) clearTimeout(this.bubbleTimer);
    this.ws?.close(1000, "leaving");
    this.ws = null;
    for (const model of this.pixels.values()) model.close();
    this.pixels.clear();
  }

  // -------------------------------------------------------------------------
  // Connection lifecycle

  private async connect(): Promise<void> {
    if (this.stopped) return;
    let grant: { token: string; wsUrl: string };
    try {
      const res = await fetch(`/api/share/sessions/${this.code}/token`, {
        method: "POST",
      });
      if (!res.ok) {
        this.session.update({ status: "unavailable" });
        return;
      }
      grant = (await res.json()) as { token: string; wsUrl: string };
    } catch {
      this.scheduleReconnect();
      return;
    }
    if (this.stopped) return;
    const url = `${grant.wsUrl}?token=${encodeURIComponent(grant.token)}`;
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    ws.onopen = () => {
      this.reconnectAttempt = 0;
      this.send({ t: "hello", proto: PROTO_VERSION });
      this.replayVolatileState();
    };
    ws.onmessage = (event) => {
      if (typeof event.data === "string") {
        this.handleServerMessage(JSON.parse(event.data) as ServerMessage);
      } else {
        this.handleBinary(new Uint8Array(event.data as ArrayBuffer));
      }
    };
    ws.onclose = (event) => {
      if (this.ws !== ws) return;
      this.ws = null;
      const s = this.session.get().status;
      // Terminal states never reconnect; 4003 is deny/kick.
      if (this.stopped || s === "ended" || s === "denied" || s === "kicked") return;
      if (event.code === 4003) {
        this.session.update({ status: "denied" });
        return;
      }
      this.scheduleReconnect();
    };
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    this.session.update({ reconnecting: true });
    const delay = Math.min(
      RECONNECT_MAX_MS,
      RECONNECT_BASE_MS * 2 ** this.reconnectAttempt,
    );
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => void this.connect(), delay);
  }

  /** Re-send focus/subs after (re)connect or a DO-side resync. */
  private replayVolatileState(): void {
    const { activeWs } = this.session.get();
    if (activeWs) this.send({ t: "focus", ws: activeWs });
    for (const key of this.subs) {
      const [ws, pane] = key.split(" ");
      if (ws && pane) this.send({ t: "sub", ws, pane });
    }
  }

  // -------------------------------------------------------------------------
  // Inbound

  private handleServerMessage(msg: ServerMessage): void {
    switch (msg.t) {
      case "session-state": {
        const layouts: Record<string, WorkspaceLayout> = {};
        for (const layout of msg.layouts) layouts[layout.ws] = layout;
        const current = this.session.get();
        const activeWs =
          current.activeWs && msg.shared.some((w) => w.id === current.activeWs)
            ? current.activeWs
            : (msg.shared[0]?.id ?? null);
        this.session.update({
          status: "active",
          reconnecting: false,
          shared: msg.shared,
          layouts,
          participants: msg.participants,
          chat: msg.chat,
          you: msg.you,
          activeWs,
        });
        if (activeWs && activeWs !== current.activeWs) {
          this.syncWorkspaceSubscriptions(activeWs);
          this.send({ t: "focus", ws: activeWs });
        }
        break;
      }
      case "access-pending":
        this.session.update({ status: "pending", reconnecting: false });
        break;
      case "access-denied":
        this.session.update({ status: "denied" });
        break;
      case "kicked":
        this.session.update({ status: "kicked" });
        break;
      case "presence": {
        this.session.update({ participants: msg.participants });
        this.maybeFollow(msg.participants);
        break;
      }
      case "shared":
        this.session.update({ shared: msg.shared });
        break;
      case "layout": {
        const layouts = {
          ...this.session.get().layouts,
          [msg.layout.ws]: msg.layout,
        };
        this.session.update({ layouts });
        if (msg.layout.ws === this.session.get().activeWs) {
          this.syncWorkspaceSubscriptions(msg.layout.ws);
        }
        break;
      }
      case "cursor": {
        const next = new Map(this.cursors.get());
        const existing = next.get(msg.user);
        next.set(msg.user, { user: msg.user, pos: msg.pos, bubble: existing?.bubble });
        this.cursors.set(next);
        break;
      }
      case "chat": {
        const chat = [...this.session.get().chat, msg.msg];
        this.session.update({ chat });
        if (msg.msg.bubble) this.showBubble(msg.msg);
        break;
      }
      case "role-changed": {
        const you = this.session.get().you;
        if (you) this.session.update({ you: { ...you, role: msg.role } });
        break;
      }
      case "compose-state": {
        const next = new Map(this.compose.get());
        next.set(msg.field, { rev: msg.rev, text: msg.text, carets: msg.carets });
        this.compose.set(next);
        break;
      }
      case "resync":
        this.replayVolatileState();
        break;
      case "session-ended":
        this.session.update({ status: "ended", endedReason: msg.reason });
        break;
      case "access-request":
      case "error":
        break; // host-only / diagnostics
      default:
        break;
    }
  }

  private handleBinary(data: Uint8Array): void {
    const frame = decodeBinaryFrame(data);
    if (!frame) return;
    const key = paneKey(frame.ws, frame.pane);
    if (frame.kind === BINARY_KIND_PIXEL) {
      this.pixelFor(frame.ws, frame.pane).push(frame.payload);
      return;
    }
    if (frame.kind !== BINARY_KIND_GRID) return;
    let model = this.grids.get(key);
    if (!model) {
      model = new TerminalGridModel();
      this.grids.set(key, model);
    }
    try {
      const parsed = JSON.parse(new TextDecoder().decode(frame.payload)) as RenderGridFrame;
      if (!model.apply(parsed)) return;
    } catch {
      return;
    }
    const listeners = this.gridListeners.get(key);
    if (listeners) for (const l of listeners) l();
  }

  private showBubble(msg: ChatMessage): void {
    const next = new Map(this.cursors.get());
    const existing = next.get(msg.user);
    next.set(msg.user, {
      user: msg.user,
      pos: existing?.pos ?? msg.bubble ?? null,
      bubble: { text: msg.text, until: Date.now() + BUBBLE_VISIBLE_MS },
    });
    this.cursors.set(next);
    if (this.bubbleTimer) clearTimeout(this.bubbleTimer);
    this.bubbleTimer = setTimeout(() => this.expireBubbles(), BUBBLE_VISIBLE_MS + 50);
  }

  private expireBubbles(): void {
    const now = Date.now();
    const next = new Map<string, RemoteCursor>();
    let changed = false;
    for (const [user, cursor] of this.cursors.get()) {
      if (cursor.bubble && cursor.bubble.until <= now) {
        next.set(user, { user: cursor.user, pos: cursor.pos });
        changed = true;
      } else {
        next.set(user, cursor);
      }
    }
    if (changed) this.cursors.set(next);
  }

  private maybeFollow(participants: Participant[]): void {
    const { followUser, activeWs } = this.session.get();
    if (!followUser) return;
    const target = participants.find((p) => p.user === followUser);
    if (target?.focusWs && target.focusWs !== activeWs) {
      this.setActiveWorkspace(target.focusWs, { keepFollow: true });
    }
  }

  // -------------------------------------------------------------------------
  // Outbound

  private send(msg: GuestMessage): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  setActiveWorkspace(ws: string, opts?: { keepFollow?: boolean }): void {
    const current = this.session.get();
    if (!current.shared.some((w) => w.id === ws)) return;
    this.session.update({
      activeWs: ws,
      followUser: opts?.keepFollow ? current.followUser : null,
    });
    this.send({ t: "focus", ws });
    this.syncWorkspaceSubscriptions(ws);
  }

  follow(user: string | null): void {
    this.session.update({ followUser: user });
    if (user) this.maybeFollow(this.session.get().participants);
  }

  /** Subscribe to every pane of the active workspace, drop the rest.
   * Terminals stream grids; browser/agent panes stream pixels (slice 2). */
  private syncWorkspaceSubscriptions(ws: string): void {
    const layout = this.session.get().layouts[ws];
    const wanted = new Set<string>();
    const visit = (node: LayoutNode | null | undefined): void => {
      if (!node) return;
      if (node.kind === "split") {
        visit(node.a);
        visit(node.b);
        return;
      }
      if (node.content !== "other") wanted.add(paneKey(ws, node.pane));
    };
    visit(layout?.tree);
    for (const key of this.subs) {
      if (!wanted.has(key)) {
        const [w, p] = key.split(" ");
        if (w && p) this.send({ t: "unsub", ws: w, pane: p });
        this.subs.delete(key);
      }
    }
    for (const key of wanted) {
      if (!this.subs.has(key)) {
        const [w, p] = key.split(" ");
        if (w && p) this.send({ t: "sub", ws: w, pane: p });
        this.subs.add(key);
      }
    }
  }

  /** Throttled pane-relative cursor updates; `null` hides the cursor. */
  sendCursor(pos: CursorPos | null): void {
    this.pendingCursor = pos;
    if (this.cursorTimer) return;
    this.cursorTimer = setTimeout(() => {
      this.cursorTimer = null;
      if (this.pendingCursor !== undefined) {
        this.send({ t: "cursor", pos: this.pendingCursor });
        this.pendingCursor = undefined;
      }
    }, CURSOR_SEND_INTERVAL_MS);
  }

  sendChat(text: string, bubble?: CursorPos): void {
    const trimmed = text.trim();
    if (!trimmed) return;
    this.send(bubble ? { t: "chat", text: trimmed, bubble } : { t: "chat", text: trimmed });
  }

  sendInput(ws: string, pane: string, data: string): void {
    if (this.session.get().you?.role !== "editor") return;
    this.send({ t: "input", ws, pane, data });
  }

  sendCompose(
    field: string,
    rev: number,
    ops: ComposeOp[],
    caret?: { start: number; end: number },
  ): void {
    if (this.session.get().you?.role !== "editor") return;
    this.send(caret ? { t: "compose", field, rev, ops, caret } : { t: "compose", field, rev, ops });
  }

  /** Interactive browser panes (slice 3). Pointer moves are rate-limited. */
  sendPointer(msg: Extract<GuestMessage, { t: "pointer" }>): void {
    if (this.session.get().you?.role !== "editor") return;
    if (msg.action === "move") {
      const now = Date.now();
      if (now - this.lastPointerMoveSent < CURSOR_SEND_INTERVAL_MS) return;
      this.lastPointerMoveSent = now;
    }
    this.send(msg);
  }

  sendWebKey(msg: Extract<GuestMessage, { t: "webkey" }>): void {
    if (this.session.get().you?.role !== "editor") return;
    this.send(msg);
  }

  // -------------------------------------------------------------------------
  // Grid access for pane canvases

  gridFor(ws: string, pane: string): TerminalGridModel {
    const key = paneKey(ws, pane);
    let model = this.grids.get(key);
    if (!model) {
      model = new TerminalGridModel();
      this.grids.set(key, model);
    }
    return model;
  }

  pixelFor(ws: string, pane: string): PixelPaneModel {
    const key = paneKey(ws, pane);
    let model = this.pixels.get(key);
    if (!model) {
      model = new PixelPaneModel();
      this.pixels.set(key, model);
    }
    return model;
  }

  subscribeGrid(ws: string, pane: string, listener: Listener): () => void {
    const key = paneKey(ws, pane);
    let set = this.gridListeners.get(key);
    if (!set) {
      set = new Set();
      this.gridListeners.set(key, set);
    }
    set.add(listener);
    return () => {
      set.delete(listener);
    };
  }
}
