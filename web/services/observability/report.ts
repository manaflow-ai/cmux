const SENSITIVE_KEY_PATTERN = /authorization|cookie|credential|dsn|key|password|providerMetadata|secret|token|webhook/i;

export function reportError(error: unknown, context: Record<string, unknown>): void {
  const safeContext = scrubContext(context);
  try {
    // Log a scrubbed summary, never the raw error: provider error messages can
    // embed credential-bearing URLs/headers and logs must stay secret-free.
    // Sentry still receives the original exception below (its own scrubbing
    // applies, and grouping needs the real error).
    console.error("cmux.observability.error", safeContext, scrubErrorForLog(error));
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

const SENSITIVE_TEXT_PATTERN = /(srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,})/g;

function scrubErrorForLog(error: unknown): string {
  const name =
    error && typeof error === "object" && typeof (error as { name?: unknown }).name === "string"
      ? (error as { name: string }).name
      : typeof error;
  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return `${name}: ${message.replace(SENSITIVE_TEXT_PATTERN, "[redacted]")}`;
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
