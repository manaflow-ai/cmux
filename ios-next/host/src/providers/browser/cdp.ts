// Minimal Chrome DevTools Protocol client over one browser-level WebSocket,
// using flattened target sessions (sessionId on each message).

import { EventEmitter } from "node:events";
import WebSocket from "ws";

export interface CdpEvents {
  event: [method: string, params: any, sessionId: string | undefined];
  close: [];
}

export class CdpError extends Error {
  constructor(
    readonly method: string,
    message: string,
  ) {
    super(`${method}: ${message}`);
  }
}

export class CdpConnection extends EventEmitter<CdpEvents> {
  private nextId = 1;
  private pending = new Map<number, { method: string; resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private closed = false;

  private constructor(private readonly ws: WebSocket) {
    super();
    ws.on("message", (data) => this.onMessage(data.toString()));
    ws.on("close", () => this.teardown());
    ws.on("error", () => this.teardown());
  }

  static connect(url: string, timeoutMs = 10_000): Promise<CdpConnection> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url, { perMessageDeflate: false, maxPayload: 256 * 1024 * 1024 });
      const timer = setTimeout(() => {
        ws.terminate();
        reject(new Error(`CDP connect timeout ${url}`));
      }, timeoutMs);
      ws.once("open", () => {
        clearTimeout(timer);
        resolve(new CdpConnection(ws));
      });
      ws.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  send<T = any>(method: string, params: Record<string, unknown> = {}, sessionId?: string, timeoutMs = 15_000): Promise<T> {
    if (this.closed) return Promise.reject(new CdpError(method, "connection closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CdpError(method, "timed out"));
      }, timeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      this.ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  }

  close(): void {
    try {
      this.ws.close();
    } catch {}
    this.teardown();
  }

  private onMessage(text: string): void {
    let msg: any;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (typeof msg.id === "number") {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new CdpError(p.method, msg.error.message ?? "error"));
      else p.resolve(msg.result ?? {});
      return;
    }
    if (typeof msg.method === "string") this.emit("event", msg.method, msg.params ?? {}, msg.sessionId);
  }

  private teardown(): void {
    if (this.closed) return;
    this.closed = true;
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new CdpError(p.method, "connection closed"));
    }
    this.pending.clear();
    this.emit("close");
  }
}
