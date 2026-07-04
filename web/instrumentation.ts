import { registerOTel } from "@vercel/otel";
import type { Instrumentation } from "next";

export async function register() {
  registerOTel({ serviceName: process.env.OTEL_SERVICE_NAME ?? "cmux-web" });
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.SENTRY_DSN?.trim()) {
    await import("./sentry.server.config");
  }
}

export const onRequestError: Instrumentation.onRequestError = async (...args) => {
  if (!process.env.SENTRY_DSN?.trim()) return;
  await import("./sentry.server.config");
  const Sentry = await import("@sentry/nextjs");
  Sentry.captureRequestError(...args);
};
