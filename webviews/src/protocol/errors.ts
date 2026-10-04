// Errors that cross the wire as `{"t":"err",...}` and errors the session raises locally.
// Session-level codes live under `cmux.protocol.*`; op-level codes come from the IR
// (`<ns>.<code>`, for example `cmux.git.not_a_repo`).

export const ProtocolErrorCode = {
  /** The transport closed before the call finished. Retrying on a new session may succeed. */
  closed: "cmux.protocol.closed",
  /** The caller aborted the call through its AbortSignal. */
  cancelled: "cmux.protocol.cancelled",
  unknownOp: "cmux.protocol.unknown_op",
  unknownStream: "cmux.protocol.unknown_stream",
  invalidParams: "cmux.protocol.invalid_params",
  invalidResult: "cmux.protocol.invalid_result",
  invalidEvent: "cmux.protocol.invalid_event",
  /** A local handler threw something that was not a ProtocolError. */
  internal: "cmux.protocol.internal",
  /** The peer sent stream bytes beyond the credit it was granted. */
  creditExceeded: "cmux.protocol.credit_exceeded",
  streamAborted: "cmux.protocol.stream_aborted",
  authRefused: "cmux.protocol.auth_refused",
} as const;

export interface ValidationIssue {
  /** JSON Pointer-like path into the checked value, "" for the root. */
  path: string;
  message: string;
}

export class ProtocolError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly details: Record<string, unknown> | undefined;

  constructor(code: string, message: string, options: { retryable?: boolean; details?: Record<string, unknown> } = {}) {
    super(message);
    this.name = "ProtocolError";
    this.code = code;
    this.retryable = options.retryable ?? false;
    this.details = options.details;
  }

  static fromIssues(code: string, what: string, issues: readonly ValidationIssue[]): ProtocolError {
    const summary = issues
      .slice(0, 5)
      .map((issue) => `${issue.path || "/"}: ${issue.message}`)
      .join("; ");
    return new ProtocolError(code, `${what}: ${summary}`, { details: { issues: issues.slice(0, 20) } });
  }
}

export function isAbortError(error: unknown): boolean {
  return error instanceof ProtocolError && error.code === ProtocolErrorCode.cancelled;
}
