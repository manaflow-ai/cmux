import {
  SpanStatusCode,
  trace,
  type Attributes,
  type Span,
} from "@opentelemetry/api";

type AttributeValue = string | number | boolean;
export type MaybeAttributes = Record<string, AttributeValue | null | undefined>;
export type SpanCallback<T> = (span: Span) => T | Promise<T>;

export async function withSpan<T>(
  tracerName: string,
  name: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
): Promise<T> {
  const tracer = trace.getTracer(tracerName);
  return tracer.startActiveSpan(name, { attributes: cleanAttributes(attributes) }, async (span) => {
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
  });
}

export async function withApiRouteSpan<T extends Response>(
  request: Request,
  route: string,
  attributes: MaybeAttributes,
  fn: SpanCallback<T>,
): Promise<T> {
  const path = requestPath(request);
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
      return response;
    },
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
      "cmux.error_message": err.message,
    });
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
