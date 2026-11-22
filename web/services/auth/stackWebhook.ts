import { createHmac, timingSafeEqual } from "node:crypto";
import { applyHexclaveWebhookEvent, type HexclaveSyncDependencies } from "./hexclave/sync";
import { parseHexclaveWebhook, type HexclaveWebhookEvent } from "./hexclave/webhookEvents";

/**
 * Hexclave (formerly Stack Auth) webhooks, delivered by Svix. Every event
 * type syncs the Hexclave mirror (services/auth/hexclave); deletions also
 * revoke Cloud machine access.
 *
 * Signature scheme (https://docs.svix.com/receiving/verifying-payloads/how-manual):
 * the signed content is `${svix-id}.${svix-timestamp}.${rawBody}`, the key is
 * the base64 secret after the `whsec_` prefix, the MAC is HMAC-SHA256, and
 * `svix-signature` is a space-separated list of `v1,<base64>` entries (one per
 * active secret during rotation). Verified here with node:crypto so the route
 * takes no new dependency.
 */

/** Svix's own default tolerance. A captured delivery replays for at most this long. */
export const SVIX_TIMESTAMP_TOLERANCE_SECONDS = 5 * 60;

export type SvixVerification =
  | { readonly ok: true }
  | { readonly ok: false; readonly reason: "missing_headers" | "invalid_secret" | "stale_timestamp" | "bad_signature" };

export function verifySvixSignature(input: {
  readonly secret: string;
  readonly headers: Headers;
  readonly rawBody: string;
  readonly nowSeconds?: number;
}): SvixVerification {
  const id = input.headers.get("svix-id");
  const timestamp = input.headers.get("svix-timestamp");
  const signatures = input.headers.get("svix-signature");
  if (!id || !timestamp || !signatures) return { ok: false, reason: "missing_headers" };

  const key = svixKey(input.secret);
  if (!key) return { ok: false, reason: "invalid_secret" };

  const sentAt = /^\d{1,12}$/.test(timestamp) ? Number(timestamp) : Number.NaN;
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (!Number.isFinite(sentAt) || Math.abs(now - sentAt) > SVIX_TIMESTAMP_TOLERANCE_SECONDS) {
    return { ok: false, reason: "stale_timestamp" };
  }

  const expected = createHmac("sha256", key).update(`${id}.${timestamp}.${input.rawBody}`).digest();
  for (const entry of signatures.split(" ")) {
    const [version, encoded] = entry.split(",", 2);
    if (version !== "v1" || !encoded) continue;
    const candidate = Buffer.from(encoded, "base64");
    if (candidate.length === expected.length && timingSafeEqual(candidate, expected)) return { ok: true };
  }
  return { ok: false, reason: "bad_signature" };
}

function svixKey(secret: string): Buffer | null {
  const trimmed = secret.trim();
  const encoded = trimmed.startsWith("whsec_") ? trimmed.slice("whsec_".length) : trimmed;
  if (!encoded) return null;
  const key = Buffer.from(encoded, "base64");
  return key.length > 0 ? key : null;
}

export type StackWebhookLog = (
  level: "info" | "warn" | "error",
  message: string,
  fields: Record<string, unknown>,
) => void;

export type StackWebhookDependencies = {
  readonly webhookSecret: () => string | undefined;
  /** Null when Hexclave server access or the database is not configured. */
  readonly sync: () => HexclaveSyncDependencies | null;
  readonly nowSeconds?: () => number;
  readonly log?: StackWebhookLog;
};

const defaultLog: StackWebhookLog = (level, message, fields) => {
  const line = JSON.stringify({ message, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.info(line);
};

/**
 * The POST handler body. Status codes are the retry contract with Svix: any
 * non-2xx is retried with backoff.
 *
 * - 401/503: the request is not provably from Hexclave, or we cannot check.
 * - 400: verified, but the body fails Hexclave's schema for its type. Logged
 *   and never processed.
 * - 200 ignored: verified, but a type this code does not know. Logged.
 * - 200 duplicate: this svix-id was already processed.
 * - 500: reconcile or revocation failed; Svix retries the same svix-id.
 * - 200 processed: only after the mirror reflects Hexclave and revocations ran.
 */
export async function handleStackWebhook(
  request: Request,
  dependencies: StackWebhookDependencies,
): Promise<Response> {
  const log = dependencies.log ?? defaultLog;
  const secret = dependencies.webhookSecret()?.trim();
  if (!secret) return json(503, { error: "stack_webhook_not_configured" });

  const rawBody = await request.text();
  const verification = verifySvixSignature({
    secret,
    headers: request.headers,
    rawBody,
    nowSeconds: dependencies.nowSeconds?.(),
  });
  if (!verification.ok) {
    const status = verification.reason === "invalid_secret" ? 503 : 401;
    return json(status, { error: "invalid_signature", reason: verification.reason });
  }
  // verifySvixSignature rejects a request without svix-id.
  const svixId = request.headers.get("svix-id") ?? "";

  const sync = dependencies.sync();
  if (!sync) return json(503, { error: "stack_webhook_sync_not_configured" });

  try {
    if (await sync.store.isEventProcessed(svixId)) {
      return json(200, { received: true, duplicate: true });
    }
  } catch (error) {
    log("error", "stack_webhook_idempotency_read_failed", { svixId, error: errorSummary(error) });
    return json(500, { error: "idempotency_unavailable" });
  }

  const parsed = await parseHexclaveWebhook(rawBody);
  switch (parsed.kind) {
    case "invalid":
      log("warn", "stack_webhook_invalid_payload", { svixId, eventType: parsed.eventType, errors: parsed.errors });
      await recordBestEffort(sync, log, { svixId, eventType: parsed.eventType ?? "unknown", outcome: "invalid" });
      return json(400, { error: "invalid_event", eventType: parsed.eventType });
    case "unknown":
      log("warn", "stack_webhook_unknown_event_type", { svixId, eventType: parsed.eventType });
      await recordBestEffort(sync, log, { svixId, eventType: parsed.eventType, outcome: "ignored" });
      return json(200, { received: true, ignored: parsed.eventType });
    case "event":
      return processEvent(svixId, parsed.event, sync, log);
  }
}

async function processEvent(
  svixId: string,
  event: HexclaveWebhookEvent,
  sync: HexclaveSyncDependencies,
  log: StackWebhookLog,
): Promise<Response> {
  try {
    const result = await applyHexclaveWebhookEvent(event, sync);
    await sync.store.recordEvent({ svixId, eventType: event.type, outcome: "processed" });
    log("info", "stack_webhook_processed", { svixId, eventType: event.type, ...result });
    return json(200, { received: true, handled: event.type });
  } catch (error) {
    log("error", "stack_webhook_sync_failed", { svixId, eventType: event.type, error: errorSummary(error) });
    await recordBestEffort(sync, log, { svixId, eventType: event.type, outcome: "failed" });
    return json(500, { error: "sync_failed" });
  }
}

async function recordBestEffort(
  sync: HexclaveSyncDependencies,
  log: StackWebhookLog,
  input: Parameters<HexclaveSyncDependencies["store"]["recordEvent"]>[0],
): Promise<void> {
  try {
    await sync.store.recordEvent(input);
  } catch (error) {
    log("error", "stack_webhook_record_failed", { svixId: input.svixId, error: errorSummary(error) });
  }
}

/**
 * A log-safe error: name, Postgres code, and the first line of the message
 * with any bound parameters cut off (Drizzle appends `params: ...`, which can
 * hold emails). HexclaveApiError details carry only status, known-error code
 * and value-free validation paths.
 */
function errorSummary(error: unknown): Record<string, unknown> {
  if (!(error instanceof Error)) return { type: typeof error };
  const details = (error as { details?: unknown }).details;
  const code = (error as { code?: unknown }).code;
  const message = (error.message.split("\n")[0] ?? "").split(/params:/i)[0]!.slice(0, 300);
  return {
    name: error.name,
    message,
    ...(typeof code === "string" ? { code } : {}),
    ...(details ? { details } : {}),
  };
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
