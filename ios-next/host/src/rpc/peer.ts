// Symmetric RPC endpoint over a Link (PROTOCOL.md §2-§3). The host server and
// the probe client both use it.

import { EventEmitter } from "node:events";
import type { ControlMessage, ErrorCode } from "../protocol.ts";
import type { Lane, Link } from "../transport/link.ts";
import { decodeFrame, encodeFrame, laneForKind } from "./frames.ts";

export class RpcError extends Error {
  constructor(
    readonly code: ErrorCode | string,
    message: string,
  ) {
    super(message);
  }
}

export type RequestHandler = (method: string, params: any) => Promise<unknown> | unknown;

const decoder = new TextDecoder();

export interface RpcPeerEvents {
  event: [topic: string, payload: any];
  frame: [kind: number, streamId: number, payload: Uint8Array];
  closed: [reason?: string];
}

export class RpcPeer extends EventEmitter<RpcPeerEvents> {
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer?: NodeJS.Timeout }>();
  handler: RequestHandler | null = null;
  private closed = false;

  constructor(
    readonly link: Link,
    private readonly log: (msg: string) => void = () => {},
  ) {
    super();
    link.on("message", (lane, data) => this.onMessage(lane, data));
    link.on("state", (state) => {
      if (state === "closed") this.teardown((link as { closeReason?: string }).closeReason);
    });
    if (link.state === "closed") queueMicrotask(() => this.teardown());
  }

  get isClosed(): boolean {
    return this.closed;
  }

  request<T = any>(method: string, params: unknown = {}, timeoutMs = 30_000): Promise<T> {
    if (this.closed) return Promise.reject(new RpcError("unavailable", "link closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const entry: { resolve: (v: any) => void; reject: (e: Error) => void; timer?: NodeJS.Timeout } = {
        resolve,
        reject,
      };
      if (timeoutMs > 0) {
        entry.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new RpcError("unavailable", `${method} timed out`));
        }, timeoutMs);
      }
      this.pending.set(id, entry);
      this.sendControl({ t: "req", id, m: method, p: params });
    });
  }

  sendEvent(topic: string, payload: unknown): void {
    this.sendControl({ t: "evt", topic, p: payload });
  }

  sendFrame(kind: number, streamId: number, payload: Uint8Array): void {
    if (this.closed || this.link.state !== "open") return;
    try {
      this.link.send(laneForKind(kind), encodeFrame(kind, streamId, payload));
    } catch (err) {
      this.log(`sendFrame failed: ${(err as Error).message}`);
    }
  }

  private sendControl(msg: ControlMessage): void {
    if (this.closed || this.link.state !== "open") return;
    try {
      this.link.send("ctl", JSON.stringify(msg));
    } catch (err) {
      this.log(`send failed: ${(err as Error).message}`);
    }
  }

  private onMessage(lane: Lane, data: Uint8Array): void {
    if (lane !== "ctl") {
      const frame = decodeFrame(data);
      if (frame) this.emit("frame", frame.kind, frame.streamId, frame.payload);
      return;
    }
    let msg: ControlMessage;
    try {
      msg = JSON.parse(decoder.decode(data));
    } catch {
      this.log("dropping malformed control message");
      return;
    }
    switch (msg.t) {
      case "req":
        void this.handleRequest(msg.id, msg.m, msg.p ?? {});
        break;
      case "res": {
        const entry = this.pending.get(msg.id);
        if (!entry) return;
        this.pending.delete(msg.id);
        if (entry.timer) clearTimeout(entry.timer);
        if (msg.ok) entry.resolve(msg.r ?? {});
        else entry.reject(new RpcError(msg.e?.code ?? "internal", msg.e?.message ?? "error"));
        break;
      }
      case "evt":
        this.emit("event", msg.topic, msg.p ?? {});
        break;
    }
  }

  private async handleRequest(id: number, method: string, params: unknown): Promise<void> {
    if (typeof id !== "number" || typeof method !== "string") return;
    try {
      if (!this.handler) throw new RpcError("unsupported", `no handler for ${method}`);
      const result = await this.handler(method, params);
      this.sendControl({ t: "res", id, ok: true, r: result ?? {} });
    } catch (err) {
      const e = err instanceof RpcError ? err : new RpcError("internal", (err as Error)?.message ?? String(err));
      if (!(err instanceof RpcError)) this.log(`${method} failed: ${(err as Error)?.stack ?? err}`);
      this.sendControl({ t: "res", id, ok: false, e: { code: e.code, message: e.message } });
    }
  }

  private teardown(reason?: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const [, entry] of this.pending) {
      if (entry.timer) clearTimeout(entry.timer);
      entry.reject(new RpcError("unavailable", "link closed"));
    }
    this.pending.clear();
    this.emit("closed", reason);
  }
}
