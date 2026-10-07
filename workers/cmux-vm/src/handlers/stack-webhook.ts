/**
 * The Stack Auth webhook (G1, cx-0op.6): `POST /v1/webhooks/stack`. No bearer
 * credential; the Svix signature with the Worker secret STACK_WEBHOOK_SECRET is
 * the credential. Outside the public API (and its OpenAPI document): only
 * Stack calls it.
 *
 * `team_membership.deleted` revokes the removed user's devices in that team
 * (revokeMemberDevices); `user.deleted` revokes the user's devices in every
 * tenant (revokeDeletedUser). Every other event is acknowledged and ignored.
 * A message is judged by the time it FIRST reached the Worker
 * (stack_webhook_events, migration 0008), the same on every retry, so a retry
 * that arrives after the user was added back and enrolled a new device never
 * revokes that device.
 * Answers: 503 while the secret is not configured or a store or the provider
 * fails (Stack retries), 401 for a bad, stale or missing signature, 400 for a
 * signed body of the wrong shape, 200 otherwise. A message processed to the
 * end is recorded by its id, so a retry of it does nothing.
 */
import { Clock, Effect, Option, type Redacted, Schema } from "effect";
import { verifyWebhookSignature } from "../auth/webhook-signature.ts";
import { WebhookDeliveryStore } from "../db/identity.ts";
import { TenantId, UserId } from "../lib/ids.ts";
import { revokeDeletedUser, revokeMemberDevices } from "./mesh.ts";

export const STACK_WEBHOOK_PATH = "/v1/webhooks/stack";
const MAX_WEBHOOK_BODY_BYTES = 64 * 1024;

const reply = (status: number, body: Record<string, unknown>) => Response.json(body, { status });

const Envelope = Schema.Struct({ type: Schema.String, data: Schema.Unknown });
const MembershipDeleted = Schema.Struct({ team_id: TenantId, user_id: UserId });
/** Stack's `user.deleted` data: the user and the teams it was in. */
const UserDeleted = Schema.Struct({ id: UserId, teams: Schema.optionalWith(Schema.Array(Schema.Struct({ id: TenantId })), { default: () => [] }) });

type RevocationEvent =
  | { readonly kind: "membership"; readonly tenantId: TenantId; readonly userId: UserId }
  | { readonly kind: "user"; readonly tenantId: null; readonly userId: UserId; readonly teams: ReadonlyArray<TenantId> };

const decodeEvent = (type: string, data: unknown): Option.Option<RevocationEvent> => {
  if (type === "team_membership.deleted") {
    return Option.map(Schema.decodeUnknownOption(MembershipDeleted)(data), (event): RevocationEvent => ({
      kind: "membership",
      tenantId: event.team_id,
      userId: event.user_id,
    }));
  }
  return Option.map(Schema.decodeUnknownOption(UserDeleted)(data), (event): RevocationEvent => ({
    kind: "user",
    tenantId: null,
    userId: event.id,
    teams: event.teams.map((team) => team.id),
  }));
};
const ACTED_ON = new Set(["team_membership.deleted", "user.deleted"]);

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
    const type = envelope.value.type;
    if (!ACTED_ON.has(type)) return reply(200, { ok: true, ignored: type });
    const decoded = decodeEvent(type, envelope.value.data);
    if (Option.isNone(decoded)) return reply(400, { _tag: "BadRequest", message: `Malformed ${type} data` });
    const event = decoded.value;
    const deliveries = yield* WebhookDeliveryStore;
    const seen = yield* deliveries.processed(check.messageId).pipe(Effect.orElseSucceed(() => false));
    if (seen) return reply(200, { ok: true, duplicate: true });
    const firstSeen = yield* Effect.either(deliveries.firstSeen(check.messageId, new Date(nowMs)));
    if (firstSeen._tag === "Left") return reply(503, { _tag: "ServiceUnavailable", message: "Revocation did not finish; retry" });
    const eventAt = firstSeen.right;
    const result = yield* Effect.either(
      event.kind === "membership" ? revokeMemberDevices(event.tenantId, event.userId, eventAt) : revokeDeletedUser(event.userId, event.teams, eventAt),
    );
    if (result._tag === "Left") return reply(503, { _tag: "ServiceUnavailable", message: "Revocation did not finish; retry" });
    const at = new Date(yield* Clock.currentTimeMillis);
    const recorded = yield* Effect.either(
      deliveries.record({ messageId: check.messageId, eventType: type, tenantId: event.tenantId, userId: event.userId, processedAt: at }),
    );
    // The revocation is done; an unrecorded delivery only means a retry repeats the (idempotent) work.
    if (recorded._tag === "Left") yield* Effect.logWarning("cmux-vm stack webhook delivery not recorded");
    return reply(200, { ok: true, ...result.right });
  });
