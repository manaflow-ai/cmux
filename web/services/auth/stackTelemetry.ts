import {
  withSpan,
  type MaybeAttributes,
  type SpanCallback,
} from "../telemetry";

/**
 * Time one Stack Auth SDK or API operation. Stack currently sends these
 * server calls through its Hexclave-compatible API headers, so the transport
 * is recorded as an attribute without exposing credentials or request data.
 */
export function withStackAuthSpan<T>(
  operation: string,
  fn: SpanCallback<T>,
  attributes: MaybeAttributes = {},
): Promise<T> {
  return withSpan(
    "cmux-stack-auth",
    `cmux.stack_auth.${operation}`,
    {
      "cmux.external.service": "stack-auth",
      "cmux.external.transport": "hexclave",
      "cmux.external.operation": operation,
      ...attributes,
    },
    fn,
  );
}
