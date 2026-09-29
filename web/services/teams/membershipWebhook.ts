import { createHmac, timingSafeEqual } from "node:crypto";

const DEFAULT_TIMESTAMP_TOLERANCE_SECONDS = 300;

export type TeamMembershipCreatedEvent = {
  readonly type: "team_membership.created";
  readonly data: { readonly team_id: string; readonly user_id: string };
};

export type ReconcileTeamMembership = (
  teamId: string,
  userId: string,
  eventId: string,
) => Promise<void>;

type WebhookDependencies = {
  readonly reconcile: ReconcileTeamMembership;
  readonly now?: () => number;
  readonly toleranceSeconds?: number;
};

/** Build a Next.js route handler for Stack membership webhooks. */
export function createStackMembershipWebhookHandler(
  dependencies: WebhookDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    const rawBody = await request.text();
    const eventId = request.headers.get("svix-id")?.trim();
    const timestampHeader = request.headers.get("svix-timestamp")?.trim();
    const signatureHeader = request.headers.get("svix-signature")?.trim();
    const secret = process.env.STACK_TEAM_WEBHOOK_SECRET?.trim();

    if (!secret || !eventId || !timestampHeader || !signatureHeader) {
      return json({ error: "unauthorized" }, 401);
    }

    const timestamp = Number(timestampHeader);
    const now = dependencies.now?.() ?? Math.floor(Date.now() / 1000);
    const tolerance = dependencies.toleranceSeconds ?? DEFAULT_TIMESTAMP_TOLERANCE_SECONDS;
    if (!Number.isInteger(timestamp) || Math.abs(now - timestamp) > tolerance) {
      return json({ error: "stale_webhook" }, 401);
    }

    if (!verifySignature(secret, eventId, timestampHeader, rawBody, signatureHeader)) {
      return json({ error: "unauthorized" }, 401);
    }

    let event: unknown;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return json({ error: "invalid_json" }, 400);
    }
    if (!isMembershipCreatedEvent(event)) {
      return json({ error: "invalid_payload" }, 400);
    }

    try {
      await dependencies.reconcile(event.data.team_id, event.data.user_id, eventId);
    } catch {
      return json({ error: "reconciliation_failed" }, 500);
    }
    return json({ ok: true }, 200);
  };
}

export function verifySignature(
  secret: string,
  eventId: string,
  timestamp: string,
  rawBody: string,
  signatureHeader: string,
): boolean {
  const encodedSecret = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  let key: Buffer;
  try {
    key = Buffer.from(encodedSecret, "base64");
  } catch {
    return false;
  }
  if (key.length === 0) return false;
  const expected = createHmac("sha256", key)
    .update(`${eventId}.${timestamp}.${rawBody}`)
    .digest("base64");
  return signatureHeader.split(/\s+/u).some((candidate) => {
    const value = candidate.startsWith("v1,") ? candidate.slice(3) : "";
    const actual = Buffer.from(value);
    const expectedBuffer = Buffer.from(expected);
    return actual.length === expectedBuffer.length && timingSafeEqual(actual, expectedBuffer);
  });
}

function isMembershipCreatedEvent(value: unknown): value is TeamMembershipCreatedEvent {
  if (!value || typeof value !== "object") return false;
  const event = value as Record<string, unknown>;
  const data = event.data;
  return (
    event.type === "team_membership.created" &&
    !!data &&
    typeof data === "object" &&
    typeof (data as Record<string, unknown>).team_id === "string" &&
    (data as Record<string, unknown>).team_id !== "" &&
    typeof (data as Record<string, unknown>).user_id === "string" &&
    (data as Record<string, unknown>).user_id !== ""
  );
}

function json(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status });
}
