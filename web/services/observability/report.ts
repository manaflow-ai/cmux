const SENSITIVE_KEY_PATTERN = /authorization|cookie|credential|dsn|key|password|providerMetadata|secret|token|webhook/i;

export function reportError(error: unknown, context: Record<string, unknown>): void {
  const safeContext = scrubContext(context);
  try {
    console.error("cmux.observability.error", safeContext, error);
  } catch {
    // Reporting must never change the caller's control flow.
  }

  if (!process.env.SENTRY_DSN?.trim()) return;

  void import("@sentry/nextjs")
    .then((Sentry) => {
      Sentry.withScope((scope) => {
        scope.setContext("cmux", safeContext);
        Sentry.captureException(error);
      });
    })
    .catch(() => {
      // Reporting must never change the caller's control flow.
    });
}

function scrubContext(context: Record<string, unknown>): Record<string, unknown> {
  const scrubbed: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(context)) {
    scrubbed[key] = scrubValue(key, value);
  }
  return scrubbed;
}

function scrubValue(key: string, value: unknown): unknown {
  if (SENSITIVE_KEY_PATTERN.test(key)) return "[redacted]";
  if (Array.isArray(value)) return value.map((entry) => scrubValue(key, entry));
  if (!value || typeof value !== "object") return value;
  const scrubbed: Record<string, unknown> = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    scrubbed[childKey] = scrubValue(childKey, childValue);
  }
  return scrubbed;
}
