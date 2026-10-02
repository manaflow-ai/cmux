/** A native bridge error keeps the resource owner's answer distinct from a lost reply. */
export type NativeErrorReply = {
  code?: unknown;
  userMessage?: unknown;
  details?: unknown;
  retryable?: unknown;
  origin?: unknown;
};
export class NativeError extends Error {
  readonly code?: string;
  readonly details?: unknown;
  readonly retryable?: boolean;
  readonly origin?: "native" | "session_host";
  constructor(reply?: NativeErrorReply) {
    super(typeof reply?.userMessage === "string" ? reply.userMessage : "Request failed");
    this.name = "NativeError";
    this.code = typeof reply?.code === "string" ? reply.code : undefined;
    this.details = reply?.details;
    this.retryable = typeof reply?.retryable === "boolean" ? reply.retryable : undefined;
    this.origin = reply?.origin === "native" || reply?.origin === "session_host" ? reply.origin : undefined;
  }
}
