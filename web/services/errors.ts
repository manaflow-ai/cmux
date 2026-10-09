import * as Sentry from "@sentry/nextjs";
import { after } from "next/server";

import { noteHandledRouteError } from "./telemetry";

const SECRET_CONTEXT_KEY =
  /^(authorization|body|cookie|credential|email|handoff(?:[_-]?lease)?|lease|prompt|response|secret|(?:access|refresh|route|handoff)?[_-]?token)$/i;
const SECRET_CONTEXT_VALUE = /\b(?:crt|crh)_[A-Za-z0-9_-]{32,}\b/g;

type CaptureContext = Record<string, string | number | boolean | null | undefined>;

export function captureBillingError(error: unknown, context: CaptureContext = {}): void {
  captureSubsystemError("billing", error, context);
}

export function captureAscError(error: unknown, context: CaptureContext = {}): void {
  captureSubsystemError("app-store-connect", error, context);
}

export function captureCoderouterError(error: unknown, context: CaptureContext = {}): void {
  // Never pass request bodies, headers, route tokens, provider credentials,
  // account labels, or email addresses into this context.
  captureSubsystemError("coderouter", error, context);
}

/**
 * The `subsystem` tag is what lets the event through the shared project's
 * beforeSend gate (services/sentry.ts shouldSendSentryEvent).
 */
function captureSubsystemError(subsystem: string, error: unknown, context: CaptureContext): void {
  noteHandledRouteError(error);
  // Read at call time, as reportError and instrumentation.ts do.
  if (!process.env.SENTRY_DSN?.trim()) return;
  Sentry.captureException(error, {
    tags: { subsystem },
    extra: cleanContext(context),
  });
  flushSentryAfterResponse();
}

/**
 * The SDK queues events, and a serverless function freezes right after its
 * response. Flush past the response, as services/observability/report.ts
 * does, so the envelope leaves the process without adding latency.
 */
export function flushSentryAfterResponse(): void {
  const flush = () => Sentry.flush(2_000).then(() => undefined, () => undefined);
  try {
    after(flush);
  } catch {
    void flush();
  }
}

function cleanContext(
  context: Record<string, string | number | boolean | null | undefined>,
): Record<string, string | number | boolean> {
  const cleaned: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(context)) {
    if (value === null || value === undefined) continue;
    if (SECRET_CONTEXT_KEY.test(key)) {
      cleaned[key] = "[Filtered]";
      continue;
    }
    cleaned[key] = typeof value === "string"
      ? value.replace(SECRET_CONTEXT_VALUE, "[Filtered token]")
      : value;
  }
  return cleaned;
}
