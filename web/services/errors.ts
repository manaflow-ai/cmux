import * as Sentry from "@sentry/nextjs";

import { env } from "../app/env";

const SECRET_CONTEXT_KEY =
  /^(authorization|body|cookie|credential|email|handoff(?:[_-]?lease)?|lease|prompt|response|secret|(?:access|refresh|route|handoff)?[_-]?token)$/i;
const SECRET_CONTEXT_VALUE = /\b(?:crt|crh)_[A-Za-z0-9_-]{32,}\b/g;

export function captureBillingError(
  error: unknown,
  context: Record<string, string | number | boolean | null | undefined> = {},
): void {
  if (!env.SENTRY_DSN) return;
  Sentry.captureException(error, {
    tags: {
      subsystem: "billing",
    },
    extra: cleanContext(context),
  });
}

export function captureAscError(
  error: unknown,
  context: Record<string, string | number | boolean | null | undefined> = {},
): void {
  if (!env.SENTRY_DSN) return;
  Sentry.captureException(error, {
    tags: {
      subsystem: "app-store-connect",
    },
    extra: cleanContext(context),
  });
}

export function captureCoderouterError(
  error: unknown,
  context: Record<string, string | number | boolean | null | undefined> = {},
): void {
  if (!env.SENTRY_DSN) return;
  Sentry.captureException(error, {
    tags: {
      subsystem: "coderouter",
    },
    // Never pass request bodies, headers, route tokens, provider credentials,
    // account labels, or email addresses into this context.
    extra: cleanContext(context),
  });
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
