// The app's acpmux transport (Swift `AgentPaneTransport`): the host owns the WebSocket, its
// endpoint and both tokens, and this page exchanges frames with it through the native bridge
// (`transport.open`, `transport.send`, `transport.close`; pushes come to
// `window.cmuxAcpmuxTransport.receive`). It has the shape of the part of `WebSocket` that direct.ts
// uses, so the protocol code is the same over the bridge, the dev slot's real socket and mock mode.
// The page never sees an endpoint or a token.
import { postNative } from "./native";
import { nativeTimedOut } from "./nativeError";
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

/// How long `transport.open` may go unanswered. A host that never replies otherwise leaves the pane
/// connecting for good, with no error and no retry; past it the socket fails as a refused open does
/// (`closeError` `transport.open_timed_out`), and the pane's handshake loop asks again. Opening
/// answers in milliseconds; a daemon that is starting is the host's wait, not this one.
// timeout: an unanswered open is a dead host reply, not slow work; the handshake loop retries after it.
export const TRANSPORT_OPEN_TIMEOUT_MS = 15_000;

/// The largest page call the app's Chromium page host takes (ChromiumPageHostBridge
/// `maximumPayloadBytes`): a larger one never leaves the page (`cmux.protocol.too_large`).
export const PAGE_HOST_CALL_BYTES = 4 << 20;
/// Room in one `transport.send` call for its envelope (the op, ids, the frames array's commas).
const CALL_SLACK = 16 << 10;
/// The most bytes one frame may take, as JSON inside its `transport.send` call.
export const BRIDGE_FRAME_BYTES = PAGE_HOST_CALL_BYTES - CALL_SLACK;
/// Most frames in one `transport.send` (AgentPaneRequest `maximumSendFrames`).
const MAX_CALL_FRAMES = 4096;

/// The UTF-8 bytes `frame` takes as a JSON string inside a call (its quotes and escapes counted).
function callBytes(frame: string): number {
  const json = JSON.stringify(frame);
  // Every UTF-16 unit is at most 3 UTF-8 bytes: most frames are counted without a walk.
  if (json.length * 3 <= BRIDGE_FRAME_BYTES) return json.length * 3;
  let bytes = 0;
  for (let at = 0; at < json.length; at += 1) {
    const code = json.charCodeAt(at);
    bytes += code < 0x80 ? 1 : code < 0x800 || (code >= 0xd800 && code < 0xe000) ? 2 : 3;
  }
  return bytes;
}

/// The id of `frame` when it is a JSON-RPC request (a notification or a reply has none to answer).
function requestId(frame: string): string | number | undefined {
  try {
    const message = JSON.parse(frame) as { id?: unknown; method?: unknown } | null;
    const id = message?.id;
    return typeof message?.method === "string" && (typeof id === "string" || typeof id === "number") ? id : undefined;
  } catch {
    return undefined;
  }
}

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
  /// The most bytes one message takes over this socket (promptBudget.ts `promptBudgetFor`).
  readonly maxMessageBytes = BRIDGE_FRAME_BYTES;
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: { code: number; reason: string; wasClean: boolean }) => void) | null = null;
  /// The host's error code when the host closed the connection (overflow, a bad first frame).
  closeError?: string;
  /// Why the open failed, when the page can tell: its deadline passed (`native.timed_out`, the wait
  /// named in `details.wait`).
  openError?: Error;
  private connection?: number;
  private outbox: string[] = [];
  private flushQueued = false;
  private openTimer?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly post: Post = postNative,
    openTimeoutMs = TRANSPORT_OPEN_TIMEOUT_MS,
  ) {
    install();
    this.openTimer = setTimeout(() => {
      this.openTimer = undefined;
      this.closeError = "transport.open_timed_out";
      this.openError = nativeTimedOut("transport.open", openTimeoutMs);
      this.failOpen();
    }, openTimeoutMs);
    this.post<{ connection: number }>("transport.open").then(
      (reply) => {
        this.stopOpenTimer();
        const connection = reply?.connection;
        if (typeof connection !== "number") return this.failOpen();
        // Closed meanwhile (by the page, or the open's deadline): the host's late connection is
        // closed, never left running with no page to read it.
        if (this.readyState === CLOSED) {
          void this.post("transport.close", { connection }).catch(() => undefined);
          return;
        }
        this.connection = connection;
        live.set(connection, this);
        this.readyState = OPEN;
        this.onopen?.(new Event("open"));
      },
      () => {
        this.stopOpenTimer();
        this.failOpen();
      },
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
    this.stopOpenTimer();
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

  /// Sends the frames written since the last flush, in order, in calls the page host takes (each at
  /// most `PAGE_HOST_CALL_BYTES`). A frame no call can carry is never sent: its request is answered
  /// at once with acpmux's own refusal of a message too large (rpc.rs `too_large`), never left to
  /// the pane's deadline (Leo, 2026-11-17: two screen recordings' frames in one prompt went
  /// unanswered for five minutes).
  private flush(): void {
    this.flushQueued = false;
    const frames = this.outbox;
    this.outbox = [];
    const connection = this.connection;
    if (!frames.length || connection === undefined || this.readyState !== OPEN) return;
    const calls: string[][] = [];
    let call: string[] = [];
    let size = 0;
    for (const frame of frames) {
      const bytes = callBytes(frame);
      if (bytes > BRIDGE_FRAME_BYTES) {
        this.answer(frame, {
          code: -32600,
          message: `message too large to send: ${bytes} bytes, the limit is ${BRIDGE_FRAME_BYTES}`,
          data: { reason: "message.too_large", bytes, limit: BRIDGE_FRAME_BYTES },
        });
        continue;
      }
      if (call.length && (size + bytes > BRIDGE_FRAME_BYTES || call.length >= MAX_CALL_FRAMES)) {
        calls.push(call);
        call = [];
        size = 0;
      }
      call.push(frame);
      size += bytes + 1;
    }
    if (call.length) calls.push(call);
    for (const sent of calls)
      void this.post("transport.send", { connection, frames: sent }).catch((error: { code?: string }) => {
        // A frame the host refused is answered on the socket (a JSON-RPC error for a request); only
        // a lost connection closes it here.
        if (error?.code && FATAL.has(error.code)) {
          this.finish({ code: 1006, reason: error.code, wasClean: false });
          return;
        }
        // No code: the call never reached the host (the page host refused it), so nothing will
        // answer its requests; they fail now.
        if (!error?.code)
          for (const frame of sent)
            this.answer(frame, {
              code: -32603,
              message: "the app did not take this request",
              data: { code: "transport.not_sent" },
            });
      });
  }

  /// Answers `frame`, when it is a request, with `error`, as acpmux's reply would come.
  private answer(frame: string, error: { code: number; message: string; data: Record<string, unknown> }): void {
    const id = requestId(frame);
    if (id === undefined) return;
    const reply = JSON.stringify({ jsonrpc: "2.0", id, error });
    queueMicrotask(() => {
      if (this.readyState === OPEN) this.onmessage?.({ data: reply });
    });
  }

  private stopOpenTimer(): void {
    if (this.openTimer !== undefined) clearTimeout(this.openTimer);
    this.openTimer = undefined;
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
