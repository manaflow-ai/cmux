import * as Sentry from "@sentry/nextjs";

import { env } from "../app/env";

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

function cleanContext(
  context: Record<string, string | number | boolean | null | undefined>,
): Record<string, string | number | boolean> {
  const cleaned: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(context)) {
    if (value !== null && value !== undefined) cleaned[key] = value;
  }
  return cleaned;
}
