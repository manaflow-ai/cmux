import type { Event } from "@sentry/nextjs";

const SECRET_KEY =
  /^(authorization|body|completion|content|cookie|email|output|prompt|provider_?account_?id|response|set-cookie|x-coderouter-route-token|x-stack-access-token|x-stack-refresh-token|access_token|refresh_token|id_token|credential|ciphertext|encryptedDataKey)$/i;
const ROUTE_TOKEN = /\bcrt_[A-Za-z0-9_-]{32,}\b/g;
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

export function shouldSendCoderouterSentryEvent(event: Event): boolean {
  if (event.tags?.subsystem === "coderouter") return true;
  const cmux = event.contexts?.cmux as Record<string, unknown> | undefined;
  if (cmux?.service === "coderouter") return true;
  // Cloud VM operator-fault errors and their Slack-alert failures report
  // through the same shared project (services/vms/observability.ts,
  // services/observability/alerts.ts). Before this branch, beforeSend
  // silently dropped them, which is how a two-day provisioning outage
  // produced zero Sentry events.
  if (typeof cmux?.subsystem === "string" && cmux.subsystem.startsWith("cloud_vm")) return true;
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
        .replace(BEARER_TOKEN, "Bearer [Filtered]")
        .replace(JWT, "[Filtered JWT]")
        .replace(API_KEY, "[Filtered API key]");
    } else {
      scrubValue(child);
    }
  }
}
