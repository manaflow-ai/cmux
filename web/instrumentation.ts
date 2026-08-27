import { registerOTel } from "@vercel/otel";
import {
  scrubSentryEvent,
  shouldSendCoderouterSentryEvent,
} from "./services/sentry";

export async function register() {
  registerOTel({ serviceName: process.env.OTEL_SERVICE_NAME ?? "cmux-web" });
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
