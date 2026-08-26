import { OTLPHttpJsonTraceExporter, registerOTel } from "@vercel/otel";
import {
  scrubSentryEvent,
  shouldSendCoderouterSentryEvent,
} from "./services/sentry";

/**
 * OTLP/HTTP span export to Axiom (https://axiom.co/docs/send-data/opentelemetry).
 * Gated on AXIOM_TOKEN + AXIOM_DATASET: with either absent, registerOTel keeps
 * its default exporter behavior and nothing changes. The VM control plane's
 * spans (withAuthedVmApiRoute / withVmSpan) carry per-stage create timings as
 * `cmux.vm.timing.<stage>_ms` attributes, so create latency is analyzable in
 * Axiom per stage.
 */
function axiomTraceExporter(): OTLPHttpJsonTraceExporter | undefined {
  const token = process.env.AXIOM_TOKEN?.trim();
  const dataset = process.env.AXIOM_DATASET?.trim();
  if (!token || !dataset) return undefined;
  const domain = process.env.AXIOM_DOMAIN?.trim() || "api.axiom.co";
  return new OTLPHttpJsonTraceExporter({
    url: `https://${domain}/v1/traces`,
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Axiom-Dataset": dataset,
    },
  });
}

export async function register() {
  const traceExporter = axiomTraceExporter();
  registerOTel({
    serviceName: process.env.OTEL_SERVICE_NAME ?? "cmux-web",
    ...(traceExporter ? { traceExporter } : {}),
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
