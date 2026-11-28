// Engine bridge transports (spec: "Engines"). Bridges carry only the handshake and native UI
// ops, so they carry text envelopes only; binary stream frames are refused.
//
// - WebKit: WKScriptMessageHandlerWithReply. `postMessage(body)` returns a promise of the
//   host's reply; a non-empty string reply is delivered as one incoming message. Host pushes
//   arrive through a page function the host calls with evaluateJavaScript.
// - CEF message router: `cefQuery({request, persistent, onSuccess, onFailure})`. Each send is
//   one non-persistent query whose response (if non-empty) is an incoming message. An optional
//   persistent "listen" query receives host pushes, one onSuccess per message.
// - CDP `Runtime.addBinding`: a one-way page function; the host answers by calling a page
//   receive function through `Runtime.evaluate`.

import { ProtocolError, ProtocolErrorCode } from "../errors";
import { BaseTransport, type TransportMessage } from "../transport";

/** Where the adapter installs host-called functions; `globalThis` in a page, a plain object in tests. */
export type GlobalTarget = Record<string, unknown>;

export const DEFAULT_RECEIVE_NAME = "__cmuxPaneProtocolReceive";

function refuseBinary(): never {
  throw new ProtocolError(ProtocolErrorCode.streamAborted, "engine bridges carry text envelopes only; use WebSocket");
}

function installReceiver(target: GlobalTarget, name: string, receive: (msg: string) => void): () => void {
  if (target[name] !== undefined) throw new Error(`${name} is already installed`);
  const fn = (msg: unknown) => {
    if (typeof msg === "string") receive(msg);
  };
  target[name] = fn;
  return () => {
    if (target[name] === fn) delete target[name];
  };
}

// WebKit

export interface WebKitReplyHandler {
  postMessage(body: unknown): Promise<unknown>;
}

export interface WebKitTransportOptions {
  handler: WebKitReplyHandler;
  /** Install a host-push receiver under this name on `target`. Omit for request/reply only. */
  receiveName?: string;
  target?: GlobalTarget;
}

/** Finds `window.webkit.messageHandlers[name]`, or null outside WebKit. */
export function findWebKitHandler(name: string, target: unknown = globalThis): WebKitReplyHandler | null {
  const handler = (target as { webkit?: { messageHandlers?: Record<string, unknown> } }).webkit?.messageHandlers?.[
    name
  ];
  return handler && typeof (handler as WebKitReplyHandler).postMessage === "function"
    ? (handler as WebKitReplyHandler)
    : null;
}

export class WebKitTransport extends BaseTransport {
  private readonly handler: WebKitReplyHandler;
  private readonly uninstall: () => void;

  constructor(options: WebKitTransportOptions) {
    super();
    this.handler = options.handler;
    this.uninstall = options.receiveName
      ? installReceiver(options.target ?? (globalThis as unknown as GlobalTarget), options.receiveName, (msg) =>
          this.deliver(msg),
        )
      : () => {};
  }

  protected sendRaw(msg: TransportMessage): void {
    if (typeof msg !== "string") refuseBinary();
    this.handler.postMessage(msg).then(
      (reply) => {
        if (typeof reply === "string" && reply.length > 0) this.deliver(reply);
      },
      (error: unknown) => {
        // The host failed the message without an envelope; pending calls cannot complete.
        this.uninstall();
        this.finish({ reason: `webkit bridge error: ${String((error as Error)?.message ?? error)}` });
      },
    );
  }

  protected closeRaw(): void {
    this.uninstall();
  }
}

// CEF message router

export interface CefQueryRequest {
  request: string;
  persistent?: boolean;
  onSuccess: (response: string) => void;
  onFailure: (errorCode: number, errorMessage: string) => void;
}

export type CefQueryFunction = (request: CefQueryRequest) => number;

export interface CefQueryTransportOptions {
  query: CefQueryFunction;
  cancel?: (queryId: number) => void;
  /** Request text for a persistent query that receives host pushes. */
  listenRequest?: string;
}

export class CefQueryTransport extends BaseTransport {
  private readonly query: CefQueryFunction;
  private readonly cancel: ((queryId: number) => void) | undefined;
  private listenId: number | null = null;

  constructor(options: CefQueryTransportOptions) {
    super();
    this.query = options.query;
    this.cancel = options.cancel;
    if (options.listenRequest !== undefined) {
      this.listenId = this.query({
        request: options.listenRequest,
        persistent: true,
        onSuccess: (response) => {
          if (response.length > 0) this.deliver(response);
        },
        onFailure: (code, message) => {
          this.listenId = null;
          this.finish({ code, reason: `cef listen query failed: ${message}` });
        },
      });
    }
  }

  protected sendRaw(msg: TransportMessage): void {
    if (typeof msg !== "string") refuseBinary();
    this.query({
      request: msg,
      persistent: false,
      onSuccess: (response) => {
        if (response.length > 0) this.deliver(response);
      },
      onFailure: (code, message) => {
        this.cancelListen();
        this.finish({ code, reason: `cef query failed: ${message}` });
      },
    });
  }

  protected closeRaw(): void {
    this.cancelListen();
  }

  private cancelListen(): void {
    if (this.listenId !== null) {
      this.cancel?.(this.listenId);
      this.listenId = null;
    }
  }
}

// CDP Runtime.addBinding

export interface CdpBindingTransportOptions {
  /** The function Runtime.addBinding installed (`window[name]`); one-way, string payload. */
  binding: (payload: string) => void;
  /** The page function the host calls via Runtime.evaluate to deliver a message. */
  receiveName?: string;
  target?: GlobalTarget;
}

export class CdpBindingTransport extends BaseTransport {
  private readonly binding: (payload: string) => void;
  private readonly uninstall: () => void;

  constructor(options: CdpBindingTransportOptions) {
    super();
    this.binding = options.binding;
    this.uninstall = installReceiver(
      options.target ?? (globalThis as unknown as GlobalTarget),
      options.receiveName ?? DEFAULT_RECEIVE_NAME,
      (msg) => this.deliver(msg),
    );
  }

  protected sendRaw(msg: TransportMessage): void {
    if (typeof msg !== "string") refuseBinary();
    this.binding(msg);
  }

  protected closeRaw(): void {
    this.uninstall();
  }
}
