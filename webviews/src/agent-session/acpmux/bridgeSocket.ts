// The app's acpmux transport (Swift `AgentPaneTransport`): the host owns the WebSocket, its
// endpoint and both tokens, and this page exchanges frames with it through the native bridge
// (`transport.open`, `transport.send`, `transport.close`; pushes come to
// `window.cmuxAcpmuxTransport.receive`). It has the shape of the part of `WebSocket` that direct.ts
// uses, so the protocol code is the same over the bridge, the dev slot's real socket and mock mode.
// The page never sees an endpoint or a token.
import { postNative } from "./native";
import { AcpmuxRpcError } from "./handoff/protocol";
import { deliverQuestionKeyRequest, isQuestionKeyRequest, type QuestionKeyRequest } from "./question/keyReply";

/// One host push: frames in arrival order, then at most once the close.
export type TransportEvent = {
  connection: number;
  frames?: string[];
  closed?: { code: number; reason: string; error?: string };
};

type Post = <T>(method: string, params?: Record<string, unknown>) => Promise<T>;

const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 3;

/// Host codes after which the connection is gone; others refuse one frame only.
const FATAL = new Set(["transport.closed", "transport.stale_connection"]);

const live = new Map<number, BridgeSocket>();

/// Routes a host push to its connection; only paired native question refusals survive its close.
export function receiveTransportEvent(event: TransportEvent): void {
  if (!event || typeof event.connection !== "number") return;
  const socket = live.get(event.connection);
  if (socket) {
    socket.receive(event);
    return;
  }
  // A connection can close between the native host's announcement and its local refusal.
  // Recover only that paired question-key error; never revive a socket or route other stale
  // frames to a new client.
  recoverClosedQuestionKeyRefusal(event);
}

function recoverClosedQuestionKeyRefusal(event: TransportEvent): void {
  const requests = new Map<string, { request: QuestionKeyRequest; announcedAt: number }>();
  for (const [index, raw] of (event.frames ?? []).entries()) {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) continue;
    const params = message.params;
    if (message.jsonrpc === "2.0" && message.method === "_cmux/question_key_request" && isQuestionKeyRequest(params)) {
      requests.set(params.id, { request: params, announcedAt: index });
      continue;
    }
    const id = message.id;
    const error = message.error;
    if (
      message.jsonrpc !== "2.0" ||
      typeof id !== "string" ||
      !error ||
      typeof error !== "object" ||
      Array.isArray(error)
    )
      continue;
    const pending = requests.get(id);
    if (!pending || pending.announcedAt >= index) continue;
    requests.delete(id);
    const rpc = error as { code?: unknown; message?: unknown; data?: unknown };
    const data = rpc.data as
      | { code?: unknown; details?: unknown; reason?: unknown; detail?: unknown; cwd?: unknown }
      | undefined;
    const refusal = Object.assign(
      new AcpmuxRpcError({
        code: rpc.code,
        message: typeof rpc.message === "string" ? rpc.message : undefined,
        data: rpc.data,
      }),
      {
        code: data?.code ?? rpc.code,
        ...(data?.details === undefined ? {} : { details: data.details }),
        ...(typeof data?.reason === "string" ? { reason: data.reason } : {}),
        ...(typeof data?.detail === "string" ? { detail: data.detail } : {}),
        ...(typeof data?.cwd === "string" ? { cwd: data.cwd } : {}),
      },
    );
    deliverQuestionKeyRequest(pending.request, Promise.reject(refusal));
  }
}

function install(): void {
  const w = window as { cmuxAcpmuxTransport?: { receive(event: TransportEvent): void } };
  if (w.cmuxAcpmuxTransport) return;
  w.cmuxAcpmuxTransport = { receive: receiveTransportEvent };
}

export class BridgeSocket {
  static readonly CONNECTING = CONNECTING;
  static readonly OPEN = OPEN;
  static readonly CLOSED = CLOSED;
  readyState = CONNECTING;
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  /// The host's error code when the host closed the connection (overflow, a bad first frame).
  closeError?: string;
  private connection?: number;
  private outbox: string[] = [];
  private flushQueued = false;

  constructor(private readonly post: Post = postNative) {
    install();
    this.post<{ connection: number }>("transport.open").then(
      (reply) => {
        const connection = reply?.connection;
        if (typeof connection !== "number") return this.failOpen();
        if (this.readyState === CLOSED) {
          void this.post("transport.close", { connection }).catch(() => undefined);
          return;
        }
        this.connection = connection;
        live.set(connection, this);
        this.readyState = OPEN;
        this.onopen?.(new Event("open"));
      },
      () => this.failOpen(),
    );
  }

  /// Queues `text`; every frame written in one task goes to the host in one bridge call, in order.
  send(text: string): void {
    if (this.readyState !== OPEN) throw new DOMException("The acpmux transport is not open", "InvalidStateError");
    this.outbox.push(text);
    if (this.flushQueued) return;
    this.flushQueued = true;
    queueMicrotask(() => this.flush());
  }

  close(): void {
    if (this.readyState === CLOSED) return;
    const connection = this.connection;
    this.finish({ code: 1000, reason: "", wasClean: true });
    if (connection !== undefined) void this.post("transport.close", { connection }).catch(() => undefined);
  }

  /// A host push for this connection.
  receive(event: TransportEvent): void {
    for (const data of event.frames ?? []) {
      if (this.readyState !== OPEN) return;
      this.onmessage?.({ data });
    }
    if (event.closed) {
      this.closeError = event.closed.error;
      this.finish({ code: event.closed.code, reason: event.closed.reason, wasClean: event.closed.code === 1000 });
    }
  }

  private flush(): void {
    this.flushQueued = false;
    const frames = this.outbox;
    this.outbox = [];
    const connection = this.connection;
    if (!frames.length || connection === undefined || this.readyState !== OPEN) return;
    void this.post("transport.send", { connection, frames }).catch((error: { code?: string }) => {
      // A refused frame is answered on the socket (a JSON-RPC error for a request); only a lost
      // connection closes it here.
      if (error?.code && FATAL.has(error.code)) this.finish({ code: 1006, reason: error.code, wasClean: false });
    });
  }

  private failOpen(): void {
    if (this.readyState === CLOSED) return;
    this.readyState = CLOSED;
    this.onerror?.(new Event("error"));
    this.onclose?.({ code: 1006, reason: "", wasClean: false });
  }

  private finish(event: { code: number; reason: string; wasClean: boolean }): void {
    if (this.readyState === CLOSED) return;
    this.readyState = CLOSED;
    if (this.connection !== undefined) live.delete(this.connection);
    this.outbox = [];
    this.onclose?.(event);
  }
}
