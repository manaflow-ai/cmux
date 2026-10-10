import { registerOTel } from "@vercel/otel";
import { DependencySpanProcessor } from "./services/observability/dependencies";
import { buildCmuxTraceSampler } from "./services/observability/sampler";
import {
  scrubSentryEvent,
  shouldSendSentryEvent,
} from "./services/sentry";
import { preconnectFreestyle } from "./services/vms/drivers/freestyleWarmup";

/** Compile the first-use Cloud routes while the development server is starting. */
function prewarmDevCloudRoutes(): void {
  if (process.env.NODE_ENV !== "development" || process.env.NEXT_RUNTIME !== "nodejs") return;
  const state = globalThis as typeof globalThis & { __cmuxDevRouteWarmupStarted?: boolean };
  if (state.__cmuxDevRouteWarmupStarted) return;
  state.__cmuxDevRouteWarmupStarted = true;
  // Establish the provider's DNS/TLS pool while the development backend is
  // coming up. The create route still awaits this shared single-flight probe
  // as a fallback when a process starts just before the first request.
  void preconnectFreestyle();
  const port = process.env.CMUX_PORT ?? process.env.PORT ?? "3000";
  const origin = `http://127.0.0.1:${port}`;
  void (async () => {
    await Promise.all([
      "/api/vm",
      "/api/vm/network-presets",
      "/api/vm/__prewarm__/stats",
      "/api/vm/tunnel",
      // Fork and the attach that follows it each compiled on first use (9.3 s
      // and 7.5 s on a fresh tag). Any method compiles the route module.
      "/api/vm/__prewarm__/fork",
      "/api/vm/__prewarm__/attach-endpoint",
    ].map(async (path) => {
      try {
        const response = await fetch(`${origin}${path}`, { signal: AbortSignal.timeout(20_000) });
        // A direct fetch is deliberately best effort. Instrumentation runs as
        // the dev server is brought up, so a refused connection or a transient
        // startup response must never delay or fail application startup.
        void response.body?.cancel();
      } catch {
        // Startup warming is best effort. The real request remains authoritative.
      }
    }));
  })();
}

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
  prewarmDevCloudRoutes();
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.SENTRY_DSN) {
    const Sentry = await import("@sentry/nextjs");
    Sentry.init({
      dsn: process.env.SENTRY_DSN,
      environment: process.env.VERCEL_ENV ?? process.env.NODE_ENV,
      release: process.env.VERCEL_GIT_COMMIT_SHA,
      sendDefaultPii: false,
      // Vercel OpenTelemetry owns tracing. This project takes deliberately
      // reported cmux errors and coderouter errors, not every request error
      // served by the shared app (see shouldSendSentryEvent).
      tracesSampleRate: 0,
      // Sentry's NodeFetch integration instruments undici on the global OTel
      // provider and emitted a bare "GET"/"POST" client span next to every
      // @vercel/otel fetch span (~175k duplicate spans per 6h in production,
      // no URL attributes). Sentry sends no traces here, so the duplicate has
      // no consumer. Postgres and the rest of the defaults stay.
      integrations: (defaults) => defaults.filter((integration) => integration.name !== "NodeFetch"),
      beforeSend: (event) =>
        shouldSendSentryEvent(event) ? scrubSentryEvent(event) : null,
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
