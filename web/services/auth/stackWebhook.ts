import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Stack Auth webhooks, delivered by Svix.
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

/** The Stack events this backend acts on; every other type is acknowledged and ignored. */
export type StackWebhookEvent =
  | { readonly type: "team_membership.deleted"; readonly teamId: string; readonly userId: string }
  | { readonly type: "team.deleted"; readonly teamId: string }
  | { readonly type: "ignored"; readonly eventType: string }
  | { readonly type: "malformed" };

/**
 * Parse a verified body. Shapes follow Stack's webhook schemas
 * (`@hexclave/shared` interface/crud): `team_membership.deleted` carries
 * `data.team_id` and `data.user_id`; `team.deleted` carries `data.id`.
 */
export function parseStackWebhookEvent(rawBody: string): StackWebhookEvent {
  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch {
    return { type: "malformed" };
  }
  if (!isRecord(body) || typeof body.type !== "string") return { type: "malformed" };
  const data = isRecord(body.data) ? body.data : {};
  if (body.type === "team_membership.deleted") {
    const teamId = nonEmptyString(data.team_id);
    const userId = nonEmptyString(data.user_id);
    return teamId && userId ? { type: body.type, teamId, userId } : { type: "malformed" };
  }
  if (body.type === "team.deleted") {
    const teamId = nonEmptyString(data.id);
    return teamId ? { type: body.type, teamId } : { type: "malformed" };
  }
  return { type: "ignored", eventType: body.type.slice(0, 64) };
}

export type StackWebhookDependencies = {
  readonly webhookSecret: () => string | undefined;
  readonly revokeTeamMemberAccess: (input: { readonly teamId: string; readonly userId: string }) => Promise<unknown>;
  readonly revokeTeamAccess: (input: { readonly teamId: string }) => Promise<unknown>;
  readonly nowSeconds?: () => number;
  readonly logError?: (message: string, error: unknown) => void;
};

/**
 * The POST handler body. Status codes are the retry contract with Svix: any
 * non-2xx is retried with backoff, so a failed revocation answers 500, and a
 * request we will never accept (bad signature, malformed body) answers 4xx.
 */
export async function handleStackWebhook(
  request: Request,
  dependencies: StackWebhookDependencies,
): Promise<Response> {
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

  const event = parseStackWebhookEvent(rawBody);
  try {
    switch (event.type) {
      case "team_membership.deleted":
        await dependencies.revokeTeamMemberAccess({ teamId: event.teamId, userId: event.userId });
        return json(200, { received: true, handled: event.type });
      case "team.deleted":
        await dependencies.revokeTeamAccess({ teamId: event.teamId });
        return json(200, { received: true, handled: event.type });
      case "ignored":
        return json(200, { received: true, ignored: event.eventType });
      case "malformed":
        return json(400, { error: "malformed_event" });
    }
  } catch (error) {
    (dependencies.logError ?? console.error)(`Stack webhook ${event.type} revocation failed`, error);
    return json(500, { error: "revocation_failed" });
  }
}

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}
