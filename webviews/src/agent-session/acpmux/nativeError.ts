import { translate } from "./i18n";
/** A native bridge error keeps the resource owner's answer distinct from a lost reply. */

/// Who failed a native request: the session host answered with a resource error, or the request
/// never got an answer (not sent, timed out, refused by the bridge, or anything else).
export type NativeErrorOrigin = "session_host" | "native";

/// The reply's error as the host sent it; each field is checked before use.
export type NativeErrorReply = {
  code?: unknown;
  userMessage?: unknown;
  details?: unknown;
  retryable?: unknown;
  origin?: unknown;
};

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
  constructor(reply?: NativeErrorReply, fallbackMessage = translate("error.requestFailed")) {
    super(typeof reply?.userMessage === "string" ? reply.userMessage : fallbackMessage);
    this.name = "NativeError";
    this.code = typeof reply?.code === "string" ? reply.code : undefined;
    this.details = reply?.details;
    this.retryable = typeof reply?.retryable === "boolean" ? reply.retryable : undefined;
    this.origin = reply?.origin === "native" || reply?.origin === "session_host" ? reply.origin : undefined;
  }
}
