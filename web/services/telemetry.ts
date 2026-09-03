import {
  context as otelContext,
  SpanStatusCode,
  trace,
  TraceFlags,
  type Attributes,
  type Context,
  type Link,
  type Span,
} from "@opentelemetry/api";

import { isVmPriorityPath } from "./observability/sampler";

/**
 * Response headers that hand the caller its Axiom lookup keys. A user who
 * pastes a failed request's reference gives operators the exact trace.
 */
export const TRACE_ID_RESPONSE_HEADER = "x-cmux-trace-id";
export const SPAN_ID_RESPONSE_HEADER = "x-cmux-span-id";

type AttributeValue = string | number | boolean;
export type MaybeAttributes = Record<string, AttributeValue | null | undefined>;
export type SpanCallback<T> = (span: Span) => T | Promise<T>;

export async function withSpan<T>(
  tracerName: string,
  name: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
  options: { readonly context?: Context; readonly links?: Link[] } = {},
): Promise<T> {
  const tracer = trace.getTracer(tracerName);
  return tracer.startActiveSpan(
    name,
    { attributes: cleanAttributes(attributes), links: options.links },
    options.context ?? otelContext.active(),
    async (span) => {
      const start = performance.now();
      try {
        return await fn(span);
      } catch (err) {
        recordSpanError(span, err);
        throw err;
      } finally {
        span.setAttribute("cmux.duration_ms", Math.round((performance.now() - start) * 100) / 100);
        span.end();
      }
    },
  );
}

export async function withApiRouteSpan<T extends Response>(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
): Promise<T> {
  const path = requestPath(request);
  // Cloud VM API spans must survive head sampling even when the surrounding
  // Next.js request trace was dropped: re-root them into their own trace
  // (linked back to the dropped one) so the priority sampler sees the
  // vm-cloud attributes on a root span and keeps the whole VM subtree.
  const parent = trace.getSpanContext(otelContext.active());
  const reRoot =
    isVmPriorityPath(route) &&
    parent !== undefined &&
    (parent.traceFlags & TraceFlags.SAMPLED) === 0;
  const links = reRoot && trace.isSpanContextValid(parent) ? [{ context: parent }] : undefined;
  return withSpan(
    "cmux-api",
    `cmux.api.${request.method} ${route}`,
    {
      "cmux.subsystem": "web",
      "cmux.runtime": "next-api",
      "http.request.method": request.method,
      "http.route": route,
      "url.path": path,
      ...attributes,
    },
    async (span) => {
      const response = await fn(span);
      span.setAttribute("http.response.status_code", response.status);
      span.setAttribute("cmux.http.response_error", response.status >= 400);
      if (response.status >= 500) {
        span.setStatus({ code: SpanStatusCode.ERROR, message: `HTTP ${response.status}` });
      }
      return withTraceIdHeaders(response, span);
    },
    // deleteSpan, not ROOT_CONTEXT: only the dropped parent span leaves the
    // context; baggage and other context values stay with the request.
    { context: reRoot ? trace.deleteSpan(otelContext.active()) : undefined, links },
  );
}

export function setSpanAttributes(span: Span, attributes: MaybeAttributes): void {
  span.setAttributes(cleanAttributes(attributes));
}

export function recordSpanError(span: Span, err: unknown): void {
  if (err instanceof Error) {
    span.recordException(err);
    span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
    span.setAttributes({
      "cmux.error_name": err.name,
      "cmux.error_message": scrubText(err.message),
    });
    const causes = summarizeErrorCauses(err);
    if (causes) {
      span.setAttributes(cleanAttributes({
        "cmux.error_cause_chain": causes.chain,
        "cmux.error_cause_depth": causes.depth,
        "cmux.error_cause_http_status": causes.httpStatus,
        "cmux.error_cause_code": causes.code,
      }));
    }
    return;
  }
  const message = String(err);
  span.recordException(message);
  span.setStatus({ code: SpanStatusCode.ERROR, message });
  span.setAttributes({
    "cmux.error_name": "NonError",
    "cmux.error_message": message,
  });
}

export type TraceIds = { readonly traceId: string; readonly spanId: string };

/** Trace and span id of a span when its context is valid, else undefined. */
export function spanTraceIds(span: Span | undefined): TraceIds | undefined {
  if (!span || typeof span.spanContext !== "function") return undefined;
  const context = span.spanContext();
  if (!trace.isSpanContextValid(context)) return undefined;
  return { traceId: context.traceId, spanId: context.spanId };
}

/** Trace ids of the active span, when one is recording. */
export function activeTraceIds(): TraceIds | undefined {
  return spanTraceIds(trace.getActiveSpan());
}

/**
 * Stamp the route span's ids on the response. Responses built by route
 * handlers have mutable headers; a response whose headers are immutable
 * (a passthrough `fetch` result) is re-wrapped around the same body.
 */
export function withTraceIdHeaders<T extends Response>(response: T, span: Span): T {
  const ids = spanTraceIds(span);
  if (!ids) return response;
  try {
    response.headers.set(TRACE_ID_RESPONSE_HEADER, ids.traceId);
    response.headers.set(SPAN_ID_RESPONSE_HEADER, ids.spanId);
    return response;
  } catch {
    const headers = new Headers(response.headers);
    headers.set(TRACE_ID_RESPONSE_HEADER, ids.traceId);
    headers.set(SPAN_ID_RESPONSE_HEADER, ids.spanId);
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    }) as T;
  }
}

/**
 * Flush buffered spans now instead of trusting the runtime's post-response
 * flush. Nine consecutive Cloud VM failures on 2026-09-01 produced no Axiom
 * spans while PostHog captures from the same requests arrived: the batch
 * exporter's deferred flush is the weak link on an error-heavy instance.
 * Best effort and bounded; never throws.
 */
export async function forceFlushTraces(timeoutMs = 3_000): Promise<boolean> {
  try {
    const provider = trace.getTracerProvider() as {
      getDelegate?: () => unknown;
      forceFlush?: () => Promise<void>;
    };
    const delegate = (provider.getDelegate?.() ?? provider) as { forceFlush?: () => Promise<void> };
    if (typeof delegate.forceFlush !== "function") return false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), timeoutMs);
    });
    const flushed = delegate.forceFlush().then(() => true, () => false);
    try {
      return await Promise.race([flushed, timeout]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  } catch {
    return false;
  }
}

const ERROR_CAUSE_MAX_DEPTH = 6;
const ERROR_CAUSE_MESSAGE_MAX = 300;
const SENSITIVE_TEXT = /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,}|crt_[A-Za-z0-9_-]{16,})/g;

type ErrorCauseSummary = {
  readonly chain: string;
  readonly depth: number;
  readonly httpStatus?: number;
  readonly code?: string;
};

/**
 * Walk `error.cause` and summarize the chain for a span: the innermost
 * provider/HTTP failure is what an operator needs, and wrapper classes such
 * as ProviderError otherwise hide it. Secrets are redacted, lengths bounded.
 */
export function summarizeErrorCauses(err: unknown): ErrorCauseSummary | undefined {
  const parts: string[] = [];
  let httpStatus: number | undefined;
  let code: string | undefined;
  let current = (err as { cause?: unknown } | null)?.cause;
  let depth = 0;
  const seen = new Set<unknown>();
  while (current && depth < ERROR_CAUSE_MAX_DEPTH && !seen.has(current)) {
    seen.add(current);
    depth += 1;
    const record = current as {
      name?: unknown;
      message?: unknown;
      code?: unknown;
      status?: unknown;
      statusCode?: unknown;
      response?: { status?: unknown };
      body?: { code?: unknown };
      cause?: unknown;
    };
    const name = typeof record.name === "string" ? record.name : typeof current;
    const message = typeof record.message === "string" ? record.message : String(current);
    parts.push(`${name}: ${scrubText(message).slice(0, ERROR_CAUSE_MESSAGE_MAX)}`);
    const status = [record.status, record.statusCode, record.response?.status].find(
      (value) => typeof value === "number" && Number.isFinite(value),
    );
    if (httpStatus === undefined && typeof status === "number") httpStatus = status;
    const causeCode = [record.body?.code, record.code].find(
      (value) => typeof value === "string" && value.length > 0,
    );
    if (code === undefined && typeof causeCode === "string") code = causeCode.slice(0, 80);
    current = record.cause;
  }
  if (depth === 0) return undefined;
  return { chain: parts.join(" <- "), depth, httpStatus, code };
}

function scrubText(text: string): string {
  return text.replace(SENSITIVE_TEXT, "[redacted]");
}

function cleanAttributes(attributes: MaybeAttributes): Attributes {
  const cleaned: Attributes = {};
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== null && value !== undefined) {
      cleaned[key] = value;
    }
  }
  return cleaned;
}

function requestPath(request: Request): string | undefined {
  try {
    return new URL(request.url).pathname;
  } catch {
    return undefined;
  }
}
