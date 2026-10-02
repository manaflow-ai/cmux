// The page's requests to the native host: Swift's `agentSession` message handler
// (CmuxNextAgentPane AgentPaneRequest), which answers `{ok: true, value}` or `{ok: false, error}`.

/// Who failed a native request: the session host answered with a resource error, or the request
/// never got an answer (not sent, timed out, refused by the bridge, or anything else).
export type NativeErrorOrigin = "session_host" | "native";

type ReplyError = {
  code?: string;
  userMessage?: string;
  details?: unknown;
  retryable?: boolean;
  origin?: NativeErrorOrigin;
};

type Reply<T> = { ok: true; value: T } | { ok: false; error?: ReplyError };

/// A refused native request. `message` is the localized text to show. With origin `session_host`,
/// `code`, `details` and `retryable` are the session host's resource error verbatim; with origin
/// `native`, `code` is `native.not_connected`, `native.timed_out`, `native.invalid_request` or
/// `native.failed`.
export class NativeError extends Error {
  readonly code: string;
  readonly details?: unknown;
  readonly retryable?: boolean;
  readonly origin: NativeErrorOrigin;

  constructor(error: ReplyError = {}, fallbackMessage = "Request failed") {
    super(error.userMessage ?? fallbackMessage);
    this.name = "NativeError";
    this.code = error.code ?? "native.failed";
    this.details = error.details;
    this.retryable = error.retryable;
    this.origin = error.origin ?? "native";
  }
}

/// Posts `method` to the native host. Rejects with a `NativeError` carrying the host's message and
/// error fields when it refuses, and when the page runs outside the app.
export function postNative<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  const handler = window.webkit?.messageHandlers?.agentSession;
  if (!handler)
    return Promise.reject(new NativeError({ code: "native.not_connected" }, "Native bridge is unavailable"));
  return Promise.resolve(handler.postMessage({ id: crypto.randomUUID(), method, params }) as unknown as Reply<T>).then(
    (reply) => {
      if (!reply.ok) throw new NativeError(reply.error);
      return reply.value;
    },
  );
}
