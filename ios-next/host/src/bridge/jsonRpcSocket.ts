// Newline-delimited JSON-RPC 2.0 client over a local Unix socket (acpmux's
// wire). Requests resolve with `result` or reject with the error object;
// notifications and server-initiated requests are emitted.

import { EventEmitter } from "node:events";
import net from "node:net";

export class JsonRpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
  }
}

export interface JsonRpcSocketEvents {
  notification: [method: string, params: any];
  close: [reason: string];
}

export class JsonRpcSocket extends EventEmitter<JsonRpcSocketEvents> {
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer?: NodeJS.Timeout }>();
  private buf = "";
  private closed = false;

  private constructor(private readonly sock: net.Socket) {
    super();
    sock.setEncoding("utf8");
    sock.on("data", (d: string) => this.onData(d));
    sock.on("close", () => this.teardown("socket closed"));
    sock.on("error", (e) => this.teardown(e.message));
  }

  static connect(path: string, timeoutMs = 5_000): Promise<JsonRpcSocket> {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection(path);
      const timer = setTimeout(() => {
        sock.destroy();
        reject(new Error(`connect timeout ${path}`));
      }, timeoutMs);
      sock.once("connect", () => {
        clearTimeout(timer);
        resolve(new JsonRpcSocket(sock));
      });
      sock.once("error", (e) => {
        clearTimeout(timer);
        reject(e);
      });
    });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  request<T = any>(method: string, params: unknown = {}, timeoutMs = 30_000): Promise<T> {
    if (this.closed) return Promise.reject(new Error("connection closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const entry: { resolve: (v: any) => void; reject: (e: Error) => void; timer?: NodeJS.Timeout } = { resolve, reject };
      if (timeoutMs > 0) {
        entry.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error(`${method} timed out`));
        }, timeoutMs);
      }
      this.pending.set(id, entry);
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: unknown = {}): void {
    if (!this.closed) this.write({ jsonrpc: "2.0", method, params });
  }

  close(): void {
    this.sock.destroy();
    this.teardown("closed");
  }

  private write(msg: unknown): void {
    this.sock.write(JSON.stringify(msg) + "\n");
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl).trim();
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.id !== undefined && msg.method === undefined) {
        const p = this.pending.get(msg.id);
        if (!p) continue;
        this.pending.delete(msg.id);
        if (p.timer) clearTimeout(p.timer);
        if (msg.error) p.reject(new JsonRpcError(msg.error.code ?? -1, msg.error.message ?? "error", msg.error.data));
        else p.resolve(msg.result);
      } else if (typeof msg.method === "string") {
        if (msg.id !== undefined) {
          // Server-initiated requests (e.g. session/request_permission) are
          // answered through acpmux's own permission API; refuse here.
          this.write({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "not handled by this client" } });
        }
        this.emit("notification", msg.method, msg.params ?? {});
      }
    }
    if (this.buf.length > 64 * 1024 * 1024) this.teardown("line too long");
  }

  private teardown(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const [, p] of this.pending) {
      if (p.timer) clearTimeout(p.timer);
      p.reject(new Error(`connection closed: ${reason}`));
    }
    this.pending.clear();
    this.emit("close", reason);
  }
}
