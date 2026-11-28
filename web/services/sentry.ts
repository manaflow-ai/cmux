import type { Event } from "@sentry/nextjs";

const SECRET_KEY =
  /^(authorization|body|completion|content|cookie|email|handoff_?lease|output|prompt|provider_?account_?id|response|set-cookie|x-cmux-authorization|x-coderouter-(route|handoff)-token|x-coderouter-handoff-lease|x-stack-access-token|x-stack-refresh-token|access_token|refresh_token|id_token|credential|ciphertext|encryptedDataKey)$/i;
const ROUTE_TOKEN = /\b(?:crt|crk)_[A-Za-z0-9_-]{32,}\b/g;
const HANDOFF_LEASE = /\bcrh_[A-Za-z0-9_-]{32,}\b/g;
const BEARER_TOKEN = /\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b/gi;
const JWT = /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b/g;
const API_KEY = /\b(?:sk|srt)_[A-Za-z0-9_-]{8,}\b/g;

/**
 * Defense in depth for telemetry. Product code must still avoid attaching
 * request bodies, auth headers, credentials, email addresses, or account
 * labels to Sentry events.
 */
export function scrubSentryEvent<T extends Event>(event: T): T {
  scrubValue(event);
  if (event.request) {
    delete event.request.data;
    delete event.request.cookies;
    delete event.request.headers;
  }
  delete event.user;
  return event;
}

/**
 * beforeSend gate for the shared cmux Sentry project. The Next.js app serves
 * far more than coderouter, and Sentry bills per event, so raw unhandled
 * request errors (`onRequestError`) stay out unless they are coderouter's.
 * Every error a cmux helper reports on purpose (`reportError`, the
 * `capture*Error` helpers in services/errors.ts) carries an explicit
 * `subsystem` tag or the `cmux` context, and passes. Until 2026-10-07 this
 * gate allowlisted a few subsystems and silently dropped the rest, including
 * App Store Connect, cron, teams and auth reports.
 */
export function shouldSendSentryEvent(event: Event): boolean {
  if (isDeliberateReport(event)) return true;
  const message =
    event.message ??
    event.exception?.values?.map((value) => value.value ?? "").join(" ") ??
    "";
  if (message.startsWith("coderouter.")) return true;
  const url = event.request?.url;
  if (!url) return false;
  try {
    return new URL(url).hostname.toLowerCase() === "coderouter.dev";
  } catch {
    return false;
  }
}

function isDeliberateReport(event: Event): boolean {
  const subsystem = event.tags?.subsystem;
  if (typeof subsystem === "string" && subsystem.trim() !== "") return true;
  // reportError (services/observability/report.ts) always sets this context
  // inside its own scope; nothing else in the app writes it.
  const cmux = event.contexts?.cmux;
  return typeof cmux === "object" && cmux !== null;
}

function scrubValue(value: unknown): void {
  if (!value || typeof value !== "object") return;
  for (const [childKey, child] of Object.entries(value)) {
    if (SECRET_KEY.test(childKey)) {
      (value as Record<string, unknown>)[childKey] = "[Filtered]";
      continue;
    }
    if (typeof child === "string") {
      (value as Record<string, unknown>)[childKey] = child
        .replace(ROUTE_TOKEN, "[Filtered route token]")
        .replace(HANDOFF_LEASE, "[Filtered handoff lease]")
        .replace(BEARER_TOKEN, "Bearer [Filtered]")
        .replace(JWT, "[Filtered JWT]")
        .replace(API_KEY, "[Filtered API key]");
    } else {
      scrubValue(child);
    }
  }
}
