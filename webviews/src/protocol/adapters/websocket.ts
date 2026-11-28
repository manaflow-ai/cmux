// WebSocket transport for pages (spec: "WebSocket auth"). The first frame is
// `{"t":"auth","token":...}`; the token never goes in the URL. A refusal is either the
// listener closing the socket or an `err` envelope with id 0 before anything else; on a
// refusal we close the socket and the connect promise (or onClose) reports auth_refused.

import { ProtocolError, ProtocolErrorCode } from "../errors";
import { BaseTransport, toUint8Array, type TransportMessage } from "../transport";

/** The subset of the DOM WebSocket the adapter uses, so tests can pass a fake. */
export interface WebSocketLike {
  readonly readyState: number;
  binaryType: string;
  send(data: string | ArrayBufferView): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: "open", listener: () => void): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  addEventListener(type: "close", listener: (event: { code?: number; reason?: string }) => void): void;
  addEventListener(type: "error", listener: () => void): void;
}

export interface WebSocketConnectOptions {
  url: string;
  token: string;
  /**
   * "none": ready as soon as the auth frame is sent (refusal arrives as a close).
   * "ok": wait for `{"t":"ok","id":0}` from the listener before resolving.
   */
  authAck?: "none" | "ok";
  /** Rejects if the socket is not ready in time. Default 5000 ms. */
  timeoutMs?: number;
  createSocket?: (url: string) => WebSocketLike;
}

const WS_OPEN = 1;
const WS_CLOSING = 2;
/** Application close code (4000-4999 range) for a refused authentication. */
export const AUTH_REFUSED_CLOSE_CODE = 4001;

export class WebSocketTransport extends BaseTransport {
  private readonly socket: WebSocketLike;
  private authenticated: boolean;
  private readonly onAuthResult: (error: ProtocolError | null) => void;

  /** @internal Use connectWebSocket. */
  constructor(socket: WebSocketLike, awaitAck: boolean, onAuthResult: (error: ProtocolError | null) => void) {
    super();
    this.socket = socket;
    this.authenticated = !awaitAck;
    this.onAuthResult = onAuthResult;
    socket.binaryType = "arraybuffer";
    socket.addEventListener("message", (event) => this.handleMessage(event.data));
    socket.addEventListener("close", (event) => {
      const refused = !this.authenticated;
      if (refused) {
        this.authenticated = true;
        this.onAuthResult(new ProtocolError(ProtocolErrorCode.authRefused, "listener closed during authentication"));
      }
      this.finish({ code: event.code, reason: event.reason || (refused ? "authentication refused" : "socket closed") });
    });
  }

  protected sendRaw(msg: TransportMessage): void {
    this.socket.send(msg);
  }

  protected closeRaw(): void {
    if (this.socket.readyState < WS_CLOSING) this.socket.close(1000, "closed");
  }

  private handleMessage(data: unknown): void {
    let msg: TransportMessage;
    if (typeof data === "string") msg = data;
    else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) msg = toUint8Array(data);
    else return;
    if (typeof msg === "string" && !this.authenticated) {
      this.handleAuthReply(msg);
      return;
    }
    if (typeof msg === "string" && this.isRefusal(msg)) {
      this.refuse(msg);
      return;
    }
    this.deliver(msg);
  }

  /** Before the first non-auth message, an `err` with id 0 is the listener refusing the token. */
  private sawTraffic = false;

  private isRefusal(text: string): boolean {
    if (this.sawTraffic) return false;
    this.sawTraffic = true;
    const parsed = safeParse(text);
    return parsed?.t === "err" && parsed.id === 0;
  }

  private handleAuthReply(text: string): void {
    const parsed = safeParse(text);
    if (parsed?.t === "ok" && parsed.id === 0) {
      this.authenticated = true;
      this.sawTraffic = true;
      this.onAuthResult(null);
      return;
    }
    this.refuse(text);
  }

  private refuse(text: string): void {
    const parsed = safeParse(text);
    const message = typeof parsed?.message === "string" ? parsed.message : "authentication refused";
    this.authenticated = true;
    // Report the refusal before finish() so a pending connect rejects with auth_refused, not
    // closed. After connect resolved, the callback is a no-op and onClose carries the reason.
    this.onAuthResult(new ProtocolError(ProtocolErrorCode.authRefused, message));
    this.finish({ code: AUTH_REFUSED_CLOSE_CODE, reason: message });
    if (this.socket.readyState < WS_CLOSING) this.socket.close(AUTH_REFUSED_CLOSE_CODE, "auth refused");
  }
}

function safeParse(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export function connectWebSocket(options: WebSocketConnectOptions): Promise<WebSocketTransport> {
  const create = options.createSocket ?? ((url: string) => new WebSocket(url) as unknown as WebSocketLike);
  const awaitAck = options.authAck === "ok";
  return new Promise<WebSocketTransport>((resolve, reject) => {
    let settled = false;
    const settle = (error: ProtocolError | null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(transport);
    };
    const socket = create(options.url);
    const transport = new WebSocketTransport(socket, awaitAck, (error) => settle(error));
    const timer = setTimeout(() => {
      transport.close();
      settle(new ProtocolError(ProtocolErrorCode.closed, "websocket connect timed out", { retryable: true }));
    }, options.timeoutMs ?? 5000);
    socket.addEventListener("open", () => {
      socket.send(JSON.stringify({ t: "auth", token: options.token }));
      if (!awaitAck) settle(null);
    });
    socket.addEventListener("error", () => {
      if (socket.readyState !== WS_OPEN) {
        settle(new ProtocolError(ProtocolErrorCode.closed, "websocket failed to connect", { retryable: true }));
      }
    });
    transport.onClose((info) => {
      settle(
        new ProtocolError(ProtocolErrorCode.closed, info.reason ?? "websocket closed", {
          retryable: true,
          details: info.code === undefined ? undefined : { code: info.code },
        }),
      );
    });
  });
}
