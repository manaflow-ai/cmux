/**
 * The Stack Auth webhook (G1, cx-0op.6): `POST /v1/webhooks/stack`. No bearer
 * credential; the Svix signature with the Worker secret STACK_WEBHOOK_SECRET is
 * the credential. Outside the public API (and its OpenAPI document): only
 * Stack calls it.
 *
 * `team_membership.deleted` revokes the removed user's devices in that team
 * (revokeMemberDevices). Every other event is acknowledged and ignored.
 * Answers: 503 while the secret is not configured or a store or the provider
 * fails (Stack retries), 401 for a bad, stale or missing signature, 400 for a
 * signed body of the wrong shape, 200 otherwise. A message processed to the
 * end is recorded by its id, so a retry of it does nothing.
 */
import { Clock, Effect, Option, type Redacted, Schema } from "effect";
import { verifyWebhookSignature } from "../auth/webhook-signature.ts";
import { WebhookDeliveryStore } from "../db/identity.ts";
import { TenantId, UserId } from "../lib/ids.ts";
import { revokeMemberDevices } from "./mesh.ts";

export const STACK_WEBHOOK_PATH = "/v1/webhooks/stack";
const MAX_WEBHOOK_BODY_BYTES = 64 * 1024;

const reply = (status: number, body: Record<string, unknown>) => Response.json(body, { status });

const Envelope = Schema.Struct({ type: Schema.String, data: Schema.Unknown });
const MembershipDeleted = Schema.Struct({ team_id: TenantId, user_id: UserId });

export const handleStackWebhook = (request: Request, secret: Redacted.Redacted<string> | undefined) =>
  Effect.gen(function* () {
    if (secret === undefined) return reply(503, { _tag: "ServiceUnavailable", message: "Stack webhooks are not configured" });
    if (request.method !== "POST") return reply(405, { _tag: "MethodNotAllowed", message: "Use POST" });
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > MAX_WEBHOOK_BODY_BYTES) return reply(413, { _tag: "PayloadTooLarge", message: "Webhook body too large" });
    const body = yield* Effect.promise(() => request.text());
    if (body.length > MAX_WEBHOOK_BODY_BYTES) return reply(413, { _tag: "PayloadTooLarge", message: "Webhook body too large" });
    const nowMs = yield* Clock.currentTimeMillis;
    const check = yield* Effect.promise(() => verifyWebhookSignature(secret, request.headers, body, nowMs));
    if (!check.ok) {
      yield* Effect.logWarning("cmux-vm stack webhook refused").pipe(Effect.annotateLogs({ reason: check.reason }));
      return check.reason === "secret"
        ? reply(503, { _tag: "ServiceUnavailable", message: "Stack webhooks are not configured" })
        : reply(401, { _tag: "Unauthorized", message: "Invalid webhook signature" });
    }
    const envelope = Schema.decodeUnknownOption(Schema.parseJson(Envelope))(body);
    if (Option.isNone(envelope)) return reply(400, { _tag: "BadRequest", message: "Malformed webhook body" });
    if (envelope.value.type !== "team_membership.deleted") return reply(200, { ok: true, ignored: envelope.value.type });
    const data = Schema.decodeUnknownOption(MembershipDeleted)(envelope.value.data);
    if (Option.isNone(data)) return reply(400, { _tag: "BadRequest", message: "Malformed team_membership.deleted data" });
    const deliveries = yield* WebhookDeliveryStore;
    const seen = yield* deliveries.processed(check.messageId).pipe(Effect.orElseSucceed(() => false));
    if (seen) return reply(200, { ok: true, duplicate: true });
    const result = yield* Effect.either(revokeMemberDevices(data.value.team_id, data.value.user_id));
    if (result._tag === "Left") return reply(503, { _tag: "ServiceUnavailable", message: "Revocation did not finish; retry" });
    const at = new Date(yield* Clock.currentTimeMillis);
    const recorded = yield* Effect.either(
      deliveries.record({ messageId: check.messageId, eventType: envelope.value.type, tenantId: data.value.team_id, userId: data.value.user_id, processedAt: at }),
    );
    // The revocation is done; an unrecorded delivery only means a retry repeats the (idempotent) work.
    if (recorded._tag === "Left") yield* Effect.logWarning("cmux-vm stack webhook delivery not recorded");
    return reply(200, { ok: true, ...result.right });
  });
