export interface SentryEnv {
  /** Sentry DSN provisioned as a Worker secret. */
  SENTRY_DSN?: string;
}

function details(error: unknown): { type: string; message: string; stack?: string } {
  if (error instanceof Error) {
    return {
      type: error.name || "Error",
      message: error.message.slice(0, 2_000),
      ...(error.stack ? { stack: error.stack.slice(0, 8_000) } : {}),
    };
  }
  return { type: "UnknownError", message: String(error).slice(0, 2_000) };
}

function parseDsn(raw: string): { endpoint: string; publicKey: string } | null {
  try {
    const url = new URL(raw);
    const projectId = url.pathname.replace(/^\/+|\/+$/g, "");
    if (!url.username || !projectId || (url.protocol !== "https:" && url.protocol !== "http:")) {
      return null;
    }
    return {
      endpoint: `${url.origin}/api/${projectId}/envelope/`,
      publicKey: decodeURIComponent(url.username),
    };
  } catch {
    return null;
  }
}

/** Sends an application exception to Sentry without an SDK dependency.
 * Sentry's envelope protocol is stable and works in Cloudflare Workers.
 * Delivery failures are swallowed so telemetry cannot change DO behavior. */
export async function captureSentryException(
  env: SentryEnv,
  distinctId: string,
  error: unknown,
  context: Record<string, string | number | boolean | undefined>,
  sentryFetch: typeof fetch = fetch,
): Promise<void> {
  const dsn = env.SENTRY_DSN ? parseDsn(env.SENTRY_DSN) : null;
  if (!dsn) return;
  const eventId = crypto.randomUUID().replace(/-/g, "");
  const value = details(error);
  const tags: Record<string, string> = { runtime: "cloudflare-worker" };
  for (const [key, item] of Object.entries(context)) {
    if (item !== undefined) tags[key] = String(item).slice(0, 200);
  }
  const event = {
    event_id: eventId,
    timestamp: Date.now() / 1_000,
    platform: "javascript",
    level: "error",
    logger: "cmux-presence",
    ...(distinctId ? { user: { id: distinctId.slice(0, 200) } } : {}),
    tags,
    exception: {
      values: [{
        type: value.type,
        value: value.message,
        ...(value.stack ? { stacktrace: { frames: [{ filename: "worker", function: value.stack }] } } : {}),
      }],
    },
  };
  const envelope = `${JSON.stringify({ event_id: eventId, sent_at: new Date().toISOString() })}\n` +
    `${JSON.stringify({ type: "event" })}\n${JSON.stringify(event)}\n`;
  try {
    await sentryFetch(
      `${dsn.endpoint}?sentry_version=7&sentry_key=${encodeURIComponent(dsn.publicKey)}&sentry_client=cmux-presence-worker/1.0`,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-sentry-envelope" },
        body: envelope,
      },
    );
  } catch {
    // Error reporting must never become a second production failure.
  }
}
