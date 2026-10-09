// Signaling WebSocket client (PROTOCOL.md §5 "Signaling"). Used by the host
// (answerer, one WebRTC peer per sessionId) and by the probe (offerer).

import { EventEmitter } from "node:events";
import WebSocket from "ws";

export type SignalFrame =
  | { type: "welcome"; peerId: string; hosts?: { hostId: string; online: boolean }[] }
  | { type: "presence"; hostId: string; online: boolean }
  | { type: "offer"; to?: string; from?: string; sessionId: string; sdp: string }
  | { type: "answer"; to?: string; from?: string; sessionId: string; sdp: string }
  | { type: "candidate"; to?: string; from?: string; sessionId: string; candidate: string; sdpMid?: string | null; sdpMLineIndex?: number | null }
  | { type: "bye"; to?: string; from?: string; sessionId: string }
  | { type: "error"; code: string; sessionId?: string; message?: string };

export interface SignalingEvents {
  frame: [frame: SignalFrame];
  open: [];
  close: [code: number, reason: string];
}

export interface SignalingOptions {
  url: () => string | Promise<string>;
  log?: (m: string) => void;
  minBackoffMs?: number;
  maxBackoffMs?: number;
  /** Ping interval to keep idle proxies from dropping the socket. */
  pingMs?: number;
}

export class SignalingClient extends EventEmitter<SignalingEvents> {
  private ws: WebSocket | null = null;
  private stopped = false;
  private attempt = 0;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private pingTimer: NodeJS.Timeout | null = null;
  peerId: string | null = null;
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
    this.ws?.close(1000, "bye");
    this.ws = null;
  }

  send(frame: SignalFrame): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(JSON.stringify(frame));
    return true;
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
    const ws = new WebSocket(url, { handshakeTimeout: 15_000 });
    this.ws = ws;
    ws.on("open", () => {
      this.attempt = 0;
      this.log("signaling connected");
      if (this.pingTimer) clearInterval(this.pingTimer);
      this.pingTimer = setInterval(() => {
        // JSON ping: the backend's Durable Object auto-responds without waking.
        if (ws.readyState === WebSocket.OPEN) ws.send('{"type":"ping"}');
      }, this.opts.pingMs ?? 25_000);
      this.emit("open");
    });
    ws.on("message", (data) => {
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
      this.log(`signaling rejected: HTTP ${res.statusCode}${res.statusCode === 401 ? " (host token invalid or revoked; run login again)" : ""}`);
      // Do not hammer the backend with a bad token.
      if (res.statusCode === 401 || res.statusCode === 403) this.attempt = Math.max(this.attempt, 10);
    });
    ws.on("error", (err) => this.log(`signaling error: ${err.message}`));
    ws.on("close", (code, reason) => {
      if (this.ws === ws) this.ws = null;
      if (this.pingTimer) clearInterval(this.pingTimer);
      this.emit("close", code, reason.toString());
      if (!this.stopped) {
        this.log(`signaling closed (${code}${reason.length ? ` ${reason}` : ""})`);
        this.scheduleReconnect();
      }
    });
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
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
