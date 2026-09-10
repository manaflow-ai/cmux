import { after } from "next/server";

import { activeTraceIds } from "../telemetry";

export type ReportErrorLevel = "error" | "warning" | "info";

export type ReportErrorOptions = {
  readonly fingerprint?: readonly string[];
  /** Sentry level; defaults to `error`. User-fault conditions report as `warning`. */
  readonly level?: ReportErrorLevel;
  /** Indexed Sentry tags (searchable); values are stringified and bounded. */
  readonly tags?: Record<string, string | number | boolean | undefined>;
  /**
   * Trace ids to attach as the event's trace context. Defaults to the active
   * OpenTelemetry span, so a Sentry issue links to its Axiom trace.
   */
  readonly trace?: { readonly traceId: string; readonly spanId?: string };
};

const SENSITIVE_KEY_PATTERN = /authorization|cookie|credential|dsn|key|password|providerMetadata|secret|token|webhook/i;

export function reportError(
  error: unknown,
  context: Record<string, unknown>,
  options: ReportErrorOptions = {},
): void {
  const trace = options.trace ?? activeTraceIds();
  const safeContext = scrubContext(
    trace ? { ...context, trace_id: trace.traceId, span_id: trace.spanId } : context,
  );
  const level = options.level ?? "error";
  try {
    // Log a scrubbed summary, never the raw error: provider error messages can
    // embed credential-bearing URLs/headers and logs must stay secret-free.
    // Sentry still receives the original exception below (its own scrubbing
    // applies, and grouping needs the real error).
    const log = level === "error" ? console.error : console.warn;
    log("cmux.observability.error", safeContext, scrubErrorForLog(error));
  } catch {
    // Reporting must never change the caller's control flow.
  }

  if (!process.env.SENTRY_DSN?.trim()) return;

  const fingerprint = options.fingerprint;
  const tags = boundedTags(options.tags, trace);
  const send = () =>
    import("@sentry/nextjs")
      .then(async (Sentry) => {
        Sentry.withScope((scope) => {
          scope.setLevel(level);
          scope.setContext("cmux", safeContext);
          scope.setTags(tags);
          if (trace) {
            // The Sentry trace context is how an issue links to its trace; we
            // export traces to Axiom, so this is the cross-tool join key.
            scope.setContext("trace", {
              trace_id: trace.traceId,
              span_id: trace.spanId ?? undefined,
            });
          }
          // A stable fingerprint groups every occurrence of one operational
          // condition (e.g. one misconfigured image env) into one Sentry issue,
          // so alert rules can fire on "first seen" without per-request noise.
          if (fingerprint && fingerprint.length > 0) {
            scope.setFingerprint([...fingerprint]);
          }
          Sentry.captureException(error);
        });
        // The SDK queues events; without an explicit flush the serverless
        // function freezes right after the response and the envelope never
        // leaves the process. Zero events reached Sentry between 2026-08-06
        // and 2026-08-27 because of this.
        await Sentry.flush(2_000);
      })
      .catch(() => {
        // Reporting must never change the caller's control flow.
      });
  try {
    // Inside a request, defer past the response so the flush cannot add
    // user-visible latency; outside one (cron bootstrap, tests) `after`
    // throws and the send runs fire-and-forget.
    after(send);
  } catch {
    void send();
  }
}

const TAG_VALUE_MAX = 200;

function boundedTags(
  tags: ReportErrorOptions["tags"],
  trace: { readonly traceId: string; readonly spanId?: string } | undefined,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(tags ?? {})) {
    if (value === undefined || value === null) continue;
    if (SENSITIVE_KEY_PATTERN.test(key)) continue;
    out[key] = String(value).slice(0, TAG_VALUE_MAX);
  }
  if (trace) out.trace_id = trace.traceId;
  return out;
}

function scrubContext(context: Record<string, unknown>): Record<string, unknown> {
  const scrubbed: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(context)) {
    scrubbed[key] = scrubValue(key, value);
  }
  return scrubbed;
}

const SENSITIVE_TEXT_PATTERN = /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,})/g;

function scrubErrorForLog(error: unknown): string {
  const name =
    error && typeof error === "object" && typeof (error as { name?: unknown }).name === "string"
      ? (error as { name: string }).name
      : typeof error;
  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return `${name}: ${message.replace(SENSITIVE_TEXT_PATTERN, "[redacted]")}`;
}

function scrubValue(key: string, value: unknown): unknown {
  if (SENSITIVE_KEY_PATTERN.test(key)) return "[redacted]";
  if (Array.isArray(value)) return value.map((entry) => scrubValue(key, entry));
  if (!value || typeof value !== "object") return value;
  const scrubbed: Record<string, unknown> = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    scrubbed[childKey] = scrubValue(childKey, childValue);
  }
  return scrubbed;
}
