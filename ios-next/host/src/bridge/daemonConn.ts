// One connection to the cmux-next daemon's Unix socket: newline-delimited
// JSON, requests {id, cmd, ...params}, responses {id, ok, data|error}, events
// {event, ...}. Every request passes the bridge policy first.

import { EventEmitter } from "node:events";
import net from "node:net";
import { checkDaemonCommand } from "./policy.ts";

export class DaemonError extends Error {
  constructor(
    readonly cmd: string,
    message: string,
    readonly code?: string,
  ) {
    super(`${cmd}: ${message}`);
  }
}

export interface DaemonConnEvents {
  event: [name: string, payload: any];
  close: [reason: string];
}

export class DaemonConn extends EventEmitter<DaemonConnEvents> {
  private nextId = 1;
  private readonly pending = new Map<number, { cmd: string; resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private buf = "";
  private closed = false;
  identity: Record<string, unknown> = {};

  private constructor(private readonly sock: net.Socket) {
    super();
    sock.setEncoding("utf8");
    sock.on("data", (d: string) => this.onData(d));
    sock.on("close", () => this.teardown("socket closed"));
    sock.on("error", (e) => this.teardown(e.message));
  }

  /** Connects, identifies and registers as a frontend client of the bridge. */
  static async open(path: string, name = "cmux-next-host (phone bridge)"): Promise<DaemonConn> {
    const sock = await new Promise<net.Socket>((resolve, reject) => {
      const s = net.createConnection(path);
      const timer = setTimeout(() => {
        s.destroy();
        reject(new Error(`daemon connect timeout ${path}`));
      }, 5_000);
      s.once("connect", () => {
        clearTimeout(timer);
        resolve(s);
      });
      s.once("error", (e) => {
        clearTimeout(timer);
        reject(e);
      });
    });
    const conn = new DaemonConn(sock);
    conn.identity = await conn.request("identify");
    await conn.request("set-client-info", { name, kind: "frontend", capabilities: ["shared-sizing-v1", "view-attachment-lease-v1"], device_kind: "phone" });
    return conn;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  request<T = any>(cmd: string, params: Record<string, unknown> = {}, timeoutMs = 15_000): Promise<T> {
    try {
      checkDaemonCommand(cmd, params);
    } catch (err) {
      return Promise.reject(err);
    }
    if (this.closed) return Promise.reject(new DaemonError(cmd, "connection closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new DaemonError(cmd, "timed out"));
      }, timeoutMs);
      this.pending.set(id, { cmd, resolve, reject, timer });
      this.sock.write(JSON.stringify({ id, cmd, ...params }) + "\n");
    });
  }

  close(): void {
    this.sock.destroy();
    this.teardown("closed");
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (!line.trim()) continue;
      let msg: any;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (typeof msg.event === "string") {
        this.emit("event", msg.event, msg);
        continue;
      }
      const p = typeof msg.id === "number" ? this.pending.get(msg.id) : undefined;
      if (!p) continue;
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.ok) p.resolve(msg.data ?? {});
      else p.reject(new DaemonError(p.cmd, String(msg.error ?? "error"), msg.error_code));
    }
    if (this.buf.length > 64 * 1024 * 1024) this.teardown("daemon line too long");
  }

  private teardown(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new DaemonError(p.cmd, `connection closed: ${reason}`));
    }
    this.pending.clear();
    this.emit("close", reason);
  }
}
