// The page's requests to the native host: Swift's `agentSession` message handler
// (CmuxNextAgentPane AgentPaneRequest), which answers `{ok: true, value}` or `{ok: false, error}`.

/// Who failed a native request: the session host answered with a resource error, or the request
/// never got an answer (not sent, timed out, refused by the bridge, or anything else).
export type NativeErrorOrigin = "session_host" | "native";

/// The reply's error as the host sent it; each field is checked before use.
type ReplyError = {
  code?: unknown;
  userMessage?: unknown;
  details?: unknown;
  retryable?: unknown;
  origin?: unknown;
};

type Reply<T> = { ok: true; value: T } | { ok: false; error?: ReplyError };

/// A refused native request. `message` is the localized text to show. With origin `session_host`,
/// `code`, `details` and `retryable` are the session host's resource error verbatim. With origin
/// `native`, a git read's `code` is `native.not_connected`, `native.timed_out`,
/// `native.invalid_request` or `native.failed`; other requests may carry other codes. A refusal
/// that says neither keeps `code` and `origin` undefined: nothing tells whether it was sent, so a
/// checkpoint mutation stays uncertain.
export class NativeError extends Error {
  readonly code?: string;
  readonly details?: unknown;
  readonly retryable?: boolean;
  readonly origin?: NativeErrorOrigin;

  constructor(error: ReplyError = {}, fallbackMessage = "Request failed") {
    super(typeof error.userMessage === "string" ? error.userMessage : fallbackMessage);
    this.name = "NativeError";
    this.code = typeof error.code === "string" ? error.code : undefined;
    this.details = error.details;
    this.retryable = typeof error.retryable === "boolean" ? error.retryable : undefined;
    this.origin = error.origin === "native" || error.origin === "session_host" ? error.origin : undefined;
  }
}

/// Posts `method` to the native host. Rejects with a `NativeError` carrying the host's message and
/// error fields when it refuses, and when the page runs outside the app.
export function postNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler)
    return Promise.reject(
      new NativeError({ code: "native.not_connected", origin: "native" }, "Native bridge is unavailable"),
    );
  return Promise.resolve(handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as Reply<T>).then(
    (reply) => {
      if (!reply.ok) throw new NativeError(reply.error);
      return reply.value;
    },
  );
}
