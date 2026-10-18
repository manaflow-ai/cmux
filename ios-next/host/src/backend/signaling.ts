// Signaling WebSocket client (PROTOCOL.md §5 "Signaling"). Used by the host
// (answerer, one WebRTC peer per sessionId) and by the probe (offerer).

import { EventEmitter } from "node:events";
import WebSocket from "ws";

/** Backend-stamped phone session family (null for legacy tokens without one). */
type Family = { family?: string | null };

export type SignalFrame =
  | { type: "welcome"; peerId: string; hosts?: { hostId: string; online: boolean }[]; revokedFamilies?: string[] }
  | { type: "presence"; hostId: string; online: boolean }
  | ({ type: "offer"; to?: string; from?: string; sessionId: string; sdp: string; policy?: "all" | "relay" } & Family)
  | ({ type: "answer"; to?: string; from?: string; sessionId: string; sdp: string } & Family)
  | ({ type: "candidate"; to?: string; from?: string; sessionId: string; candidate: string; sdpMid?: string | null; sdpMLineIndex?: number | null } & Family)
  | ({ type: "bye"; to?: string; from?: string; sessionId: string } & Family)
  | { type: "revoked"; family: string }
  | { type: "error"; code: string; sessionId?: string; message?: string };

export interface SignalingEvents {
  frame: [frame: SignalFrame];
  open: [];
  close: [code: number, reason: string];
  /**
   * The credential is no longer valid (host removed 4003, account deleted
   * 4004, or the handshake rejected with 401/403). The client has stopped.
   */
  revoked: [reason: string];
}

/** Close codes the backend uses to evict a peer for good. */
export const REVOKED_CLOSE_CODES: Record<number, string> = {
  4003: "this Mac was removed from your account",
  4004: "the account was deleted",
};

export interface SignalingOptions {
  /** wss://.../v1/signal without credentials. */
  url: () => string | Promise<string>;
  /** Bearer token sent as the Authorization header (query fallback only if the header is rejected). */
  token?: () => string | undefined;
  log?: (m: string) => void;
  minBackoffMs?: number;
  maxBackoffMs?: number;
  /** Ping interval to keep idle proxies from dropping the socket. */
  pingMs?: number;
  /**
   * No frame (not even a pong) for this long means the socket is dead even
   * if TCP has not noticed: terminate and reconnect. Default 2 pings + 10 s.
   */
  deadAfterMs?: number;
  /** How long a frame queued while disconnected stays worth sending. */
  outboxTtlMs?: number;
}

export interface SendOptions {
  /** Queue the frame if the socket is down and send it after the reconnect. */
  queue?: boolean;
  /** Checked before a queued frame is flushed; true drops it. */
  isStale?: () => boolean;
  /** Rebuilds a queued frame at flush time (e.g. the phone's peerId moved). */
  rebuild?: () => SignalFrame;
}

interface Queued {
  frame: SignalFrame;
  at: number;
  isStale?: () => boolean;
  rebuild?: () => SignalFrame;
}

const OUTBOX_MAX = 512;

export class SignalingClient extends EventEmitter<SignalingEvents> {
  private ws: WebSocket | null = null;
  private stopped = false;
  private attempt = 0;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private pingTimer: NodeJS.Timeout | null = null;
  private outbox: Queued[] = [];
  private lastRx = 0;
  private openedAt = 0;
  peerId: string | null = null;
  /** "header" until the backend rejects it; then one "query" attempt. */
  private authMode: "header" | "query" = "header";
  private authConfirmed = false;
  private readonly log: (m: string) => void;

  constructor(private readonly opts: SignalingOptions) {
    super();
    this.log = opts.log ?? (() => {});
  }

  get isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  start(): void {
    this.stopped = false;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.outbox = [];
    this.ws?.close(1000, "bye");
    this.ws = null;
  }

  /**
   * Sends a frame now. With `queue`, a frame sent while the socket is down
   * (a drop in the middle of a negotiation) is kept and flushed after the
   * reconnect instead of being lost. Returns whether it was sent right away.
   */
  send(frame: SignalFrame, opts: SendOptions = {}): boolean {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(frame));
      return true;
    }
    if (opts.queue && !this.stopped) {
      this.outbox.push({ frame, at: Date.now(), isStale: opts.isStale, rebuild: opts.rebuild });
      if (this.outbox.length > OUTBOX_MAX) this.outbox.splice(0, this.outbox.length - OUTBOX_MAX);
    }
    return false;
  }

  /** Frames waiting for the reconnect (tests, diagnostics). */
  get queued(): number {
    return this.outbox.length;
  }

  private flushOutbox(ws: WebSocket): void {
    const ttl = this.opts.outboxTtlMs ?? 30_000;
    const now = Date.now();
    const items = this.outbox.splice(0);
    let sent = 0;
    for (const q of items) {
      if (now - q.at > ttl || q.isStale?.()) continue;
      ws.send(JSON.stringify(q.rebuild ? q.rebuild() : q.frame));
      sent += 1;
    }
    if (items.length > 0) this.log(`signaling: sent ${sent} frame(s) queued while disconnected${sent < items.length ? `, dropped ${items.length - sent} stale` : ""}`);
  }

  /** Resolves on the next welcome frame. */
  waitWelcome(timeoutMs = 15_000): Promise<Extract<SignalFrame, { type: "welcome" }>> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.off("frame", onFrame);
        reject(new Error("signaling welcome timeout"));
      }, timeoutMs);
      const onFrame = (f: SignalFrame) => {
        if (f.type !== "welcome") return;
        clearTimeout(timer);
        this.off("frame", onFrame);
        resolve(f);
      };
      this.on("frame", onFrame);
    });
  }

  private async connect(): Promise<void> {
    if (this.stopped) return;
    let url: string;
    try {
      url = await this.opts.url();
    } catch (err) {
      this.log(`signaling url failed: ${(err as Error).message}`);
      this.scheduleReconnect();
      return;
    }
    const token = this.opts.token?.();
    if (token && this.authMode === "query") {
      const u = new URL(url);
      u.searchParams.set("token", token);
      url = u.toString();
    }
    const ws = new WebSocket(url, {
      handshakeTimeout: 15_000,
      headers: token && this.authMode === "header" ? { authorization: `Bearer ${token}` } : {},
    });
    this.ws = ws;
    ws.on("open", () => {
      this.attempt = 0;
      this.authConfirmed = true;
      this.openedAt = this.lastRx = Date.now();
      this.log("signaling connected");
      if (this.pingTimer) clearInterval(this.pingTimer);
      const pingMs = this.opts.pingMs ?? 25_000;
      const deadAfter = this.opts.deadAfterMs ?? pingMs * 2 + 10_000;
      this.pingTimer = setInterval(() => {
        if (ws.readyState !== WebSocket.OPEN) return;
        if (Date.now() - this.lastRx > deadAfter) {
          // No pong for two pings: the path is gone even if TCP has not
          // noticed. Reconnect now rather than leave offers going nowhere.
          this.log(`signaling: no reply for ${Math.round((Date.now() - this.lastRx) / 1000)} s; reconnecting`);
          ws.terminate();
          return;
        }
        // JSON ping: the backend's Durable Object auto-responds without waking.
        ws.send('{"type":"ping"}');
      }, pingMs);
      this.flushOutbox(ws);
      this.emit("open");
    });
    ws.on("message", (data) => {
      this.lastRx = Date.now();
      let frame: SignalFrame;
      try {
        frame = JSON.parse(data.toString());
      } catch {
        return;
      }
      if ((frame as { type: string }).type === "pong") return;
      if (frame.type === "welcome") this.peerId = frame.peerId;
      this.emit("frame", frame);
    });
    ws.on("unexpected-response", (_req, res) => {
      const status = res.statusCode ?? 0;
      this.log(`signaling rejected: HTTP ${status}`);
      res.resume();
      if (status === 401 || status === 403) {
        if (this.opts.token && this.authMode === "header" && !this.authConfirmed) {
          // Older backend without Authorization support on the upgrade.
          this.authMode = "query";
          this.attempt = 0;
        } else if (this.opts.token) {
          this.revoke(`the backend rejected the credential (HTTP ${status})`);
          return;
        }
      }
      // With an unexpected-response listener ws does not abort on its own;
      // terminate so "close" fires and the reconnect loop continues.
      ws.terminate();
    });
    ws.on("error", (err) => this.log(`signaling error: ${err.message}`));
    ws.on("close", (code, reason) => {
      if (this.ws === ws) this.ws = null;
      if (this.pingTimer) clearInterval(this.pingTimer);
      this.emit("close", code, reason.toString());
      const revoked = REVOKED_CLOSE_CODES[code];
      if (revoked && !this.stopped) {
        this.revoke(revoked);
        return;
      }
      if (!this.stopped) {
        const up = this.openedAt ? `after ${Math.round((Date.now() - this.openedAt) / 1000)} s, last frame ${Math.round((Date.now() - this.lastRx) / 1000)} s ago` : "before opening";
        this.openedAt = 0;
        this.log(`signaling closed (${code}${reason.length ? ` ${reason}` : ""}) ${up}`);
        this.scheduleReconnect();
      }
    });
  }

  private revoke(reason: string): void {
    if (this.stopped) return;
    this.log(`signaling: ${reason}`);
    this.stop();
    this.emit("revoked", reason);
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    if (this.attempt === 0) {
      // First retry after a working connection dropped: go right away (an
      // offer may be waiting), then back off.
      this.attempt = 1;
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        void this.connect();
      }, 50);
      return;
    }
    const min = this.opts.minBackoffMs ?? 1_000;
    const max = this.opts.maxBackoffMs ?? 30_000;
    const base = Math.min(max, min * 2 ** this.attempt);
    const delay = Math.round(base / 2 + Math.random() * (base / 2));
    this.attempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connect();
    }, delay);
  }
}
