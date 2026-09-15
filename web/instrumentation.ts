import { registerOTel } from "@vercel/otel";
import { DependencySpanProcessor } from "./services/observability/dependencies";
import { buildCmuxTraceSampler } from "./services/observability/sampler";
import {
  scrubSentryEvent,
  shouldSendCoderouterSentryEvent,
} from "./services/sentry";

export async function register() {
  registerOTel({
    serviceName: process.env.OTEL_SERVICE_NAME ?? "cmux-web",
    // Keep 100% of Cloud VM traces, sample the rest (CMUX_OTEL_BASE_SAMPLE_RATIO,
    // default 2%). The unsampled firehose measured ~4M spans/15min in production.
    traceSampler: buildCmuxTraceSampler(),
    // "auto" keeps the default OTLP export; the dependency processor stamps
    // cmux.dep.* (third party name, templated route) on every outbound span so
    // Axiom can report failure rate and latency per dependency and endpoint.
    spanProcessors: ["auto", new DependencySpanProcessor()],
  });
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.SENTRY_DSN) {
    const Sentry = await import("@sentry/nextjs");
    Sentry.init({
      dsn: process.env.SENTRY_DSN,
      environment: process.env.VERCEL_ENV ?? process.env.NODE_ENV,
      release: process.env.VERCEL_GIT_COMMIT_SHA,
      sendDefaultPii: false,
      // Vercel OpenTelemetry owns tracing. This project is intentionally only
      // for coderouter errors, not every request served by the shared cmux app.
      tracesSampleRate: 0,
      // Sentry's NodeFetch integration instruments undici on the global OTel
      // provider and emitted a bare "GET"/"POST" client span next to every
      // @vercel/otel fetch span (~175k duplicate spans per 6h in production,
      // no URL attributes). Sentry sends no traces here, so the duplicate has
      // no consumer. Postgres and the rest of the defaults stay.
      integrations: (defaults) => defaults.filter((integration) => integration.name !== "NodeFetch"),
      beforeSend: (event) =>
        shouldSendCoderouterSentryEvent(event) ? scrubSentryEvent(event) : null,
    });
  }
}

export async function onRequestError(
  ...args: Parameters<typeof import("@sentry/nextjs").captureRequestError>
) {
  if (process.env.NEXT_RUNTIME !== "nodejs" || !process.env.SENTRY_DSN) return;
  const Sentry = await import("@sentry/nextjs");
  return Sentry.captureRequestError(...args);
}
