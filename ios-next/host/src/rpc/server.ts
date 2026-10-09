// Host side of the RPC protocol: method registry, host.hello gating, event
// broadcast and per-client binary streams. Transport agnostic: attach() takes
// any Link.

import { EventEmitter } from "node:events";
import { FrameKind, PROTOCOL_VERSION } from "../protocol.ts";
import type { Link } from "../transport/link.ts";
import { RpcError, RpcPeer } from "./peer.ts";

export interface HostInfo {
  hostId: string;
  hostName: string;
  os: string;
  version: string;
  capabilities: string[];
}

export interface StreamSink {
  kind: "term" | "browser";
  /** Terminal id or tab id this stream belongs to. */
  target: string;
  onInput?(data: Uint8Array): void;
  dispose(): void;
}

export type MethodHandler = (params: any, session: ClientSession) => Promise<unknown> | unknown;

let sessionCounter = 0;

export class ClientSession {
  readonly id = `c${++sessionCounter}`;
  helloed = false;
  client: { name?: string; version?: string; platform?: string } = {};
  readonly streams = new Map<number, StreamSink>();

  constructor(
    readonly server: RpcServer,
    readonly peer: RpcPeer,
  ) {}

  get open(): boolean {
    return !this.peer.isClosed;
  }

  sendFrame(kind: number, streamId: number, payload: Uint8Array): void {
    this.peer.sendFrame(kind, streamId, payload);
  }

  sendEvent(topic: string, payload: unknown): void {
    this.peer.sendEvent(topic, payload);
  }

  addStream(sink: StreamSink): number {
    const id = this.server.allocStreamId();
    this.streams.set(id, sink);
    return id;
  }

  removeStream(streamId: number): boolean {
    const sink = this.streams.get(streamId);
    if (!sink) return false;
    this.streams.delete(streamId);
    sink.dispose();
    return true;
  }

  /** Removes every stream of this kind bound to target. */
  removeStreamsFor(kind: StreamSink["kind"], target: string): void {
    for (const [id, sink] of [...this.streams]) if (sink.kind === kind && sink.target === target) this.removeStream(id);
  }

  disposeAll(): void {
    for (const id of [...this.streams.keys()]) this.removeStream(id);
  }
}

export interface RpcServerEvents {
  session: [session: ClientSession];
  sessionClosed: [session: ClientSession];
}

export class RpcServer extends EventEmitter<RpcServerEvents> {
  private readonly methods = new Map<string, MethodHandler>();
  readonly sessions = new Set<ClientSession>();
  private nextStreamId = 1;

  constructor(
    private readonly hostInfo: () => HostInfo,
    private readonly log: (msg: string) => void = () => {},
  ) {
    super();
    this.register("host.hello", (p, s) => this.hello(p, s));
    this.register("host.ping", () => ({ at: Date.now() }));
  }

  register(method: string, handler: MethodHandler): void {
    this.methods.set(method, handler);
  }

  allocStreamId(): number {
    const id = this.nextStreamId;
    this.nextStreamId = this.nextStreamId >= 0x7fffffff ? 1 : this.nextStreamId + 1;
    return id;
  }

  /** Pushes an event to every client that completed host.hello. */
  broadcast(topic: string, payload: unknown): void {
    for (const s of this.sessions) if (s.helloed && s.open) s.sendEvent(topic, payload);
  }

  attach(link: Link): ClientSession {
    const peer = new RpcPeer(link, this.log);
    const session = new ClientSession(this, peer);
    this.sessions.add(session);
    peer.handler = async (method, params) => {
      if (method !== "host.hello" && !session.helloed) {
        throw new RpcError("unauthorized", "host.hello must be the first request");
      }
      const handler = this.methods.get(method);
      if (!handler) throw new RpcError("unsupported", `unknown method ${method}`);
      return handler(params && typeof params === "object" ? params : {}, session);
    };
    peer.on("frame", (kind, streamId, payload) => {
      if (!session.helloed) return;
      if (kind !== FrameKind.termInput) return;
      session.streams.get(streamId)?.onInput?.(payload);
    });
    peer.on("closed", (reason) => {
      this.log(`client ${session.id} closed${reason ? `: ${reason}` : ""}`);
      session.disposeAll();
      this.sessions.delete(session);
      this.emit("sessionClosed", session);
    });
    this.log(`client ${session.id} attached over ${link.describe()}`);
    this.emit("session", session);
    return session;
  }

  private hello(p: any, session: ClientSession): unknown {
    if (p.protocol !== undefined && p.protocol !== PROTOCOL_VERSION) {
      throw new RpcError("unsupported", `protocol ${p.protocol} not supported (host speaks ${PROTOCOL_VERSION})`);
    }
    session.helloed = true;
    session.client = p.client ?? {};
    this.log(`hello from ${session.client.name ?? "?"} ${session.client.version ?? ""} (${session.client.platform ?? "?"})`);
    return { ...this.hostInfo(), protocol: PROTOCOL_VERSION };
  }
}

// --- param validation helpers ---

export function str(p: any, key: string): string {
  const v = p?.[key];
  if (typeof v !== "string" || v.length === 0) throw new RpcError("bad_request", `${key} must be a non-empty string`);
  return v;
}

export function optStr(p: any, key: string): string | undefined {
  const v = p?.[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") throw new RpcError("bad_request", `${key} must be a string`);
  return v;
}

export function num(p: any, key: string, fallback?: number): number {
  const v = p?.[key];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (fallback !== undefined && (v === undefined || v === null)) return fallback;
  throw new RpcError("bad_request", `${key} must be a number`);
}

export function bool(p: any, key: string): boolean {
  const v = p?.[key];
  if (typeof v !== "boolean") throw new RpcError("bad_request", `${key} must be a boolean`);
  return v;
}
