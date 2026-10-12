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
 * revokes that device, while every device from before the event is revoked
 * even when the user was added back. An event with nothing to revoke is a
 * recorded 200.
 * Answers: 503 while the secret is not configured or a store or the provider
 * fails (Stack retries), 401 for a bad, stale or missing signature, 400 for a
 * signed body of the wrong shape, 200 otherwise. A message processed to the
 * end is recorded by its id, so a retry of it does nothing. Every answer is
 * logged with its reason and the svix-id (never the secret, a signature, a
 * user id or the body), so a delivery that changed nothing shows why.
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

/** Log fields of one delivery: ids and outcome only, never the secret, a signature, a user id or the body. */
type LogFields = Readonly<Record<string, string | number | boolean>>;

/**
 * Answers `status` and logs one line with the reason (warning for every
 * refusal or failure, info for 200), so a delivery that changed nothing is
 * visible in the Worker log.
 */
const finish = (status: number, reason: string, body: Record<string, unknown>, fields: LogFields = {}) =>
  (status === 200 ? Effect.logInfo("cmux-vm stack webhook") : Effect.logWarning("cmux-vm stack webhook refused")).pipe(
    Effect.annotateLogs({ status, reason, ...fields }),
    Effect.as(reply(status, body)),
  );

/** The svix-id, as logged: the delivery's id in the Svix dashboard (not a secret), cut to 64 characters. */
const messageIdOf = (request: Request) => (request.headers.get("svix-id") ?? "").slice(0, 64);

export const handleStackWebhook = (request: Request, secret: Redacted.Redacted<string> | undefined) =>
  Effect.gen(function* () {
    const messageId = messageIdOf(request);
    const notConfigured = { _tag: "ServiceUnavailable", message: "Stack webhooks are not configured" };
    const retry = { _tag: "ServiceUnavailable", message: "Revocation did not finish; retry" };
    if (secret === undefined) return yield* finish(503, "not_configured", notConfigured, { messageId });
    if (request.method !== "POST") return yield* finish(405, "method", { _tag: "MethodNotAllowed", message: "Use POST" }, { messageId });
    const declared = Number(request.headers.get("content-length") ?? "0");
    const tooLarge = { _tag: "PayloadTooLarge", message: "Webhook body too large" };
    if (declared > MAX_WEBHOOK_BODY_BYTES) return yield* finish(413, "too_large", tooLarge, { messageId, bytes: declared });
    const body = yield* Effect.promise(() => request.text());
    if (body.length > MAX_WEBHOOK_BODY_BYTES) return yield* finish(413, "too_large", tooLarge, { messageId, bytes: body.length });
    const nowMs = yield* Clock.currentTimeMillis;
    const check = yield* Effect.promise(() => verifyWebhookSignature(secret, request.headers, body, nowMs));
    if (!check.ok) {
      // "secret": STACK_WEBHOOK_SECRET is not a valid whsec_ key; the rest are the sender's fault.
      if (check.reason === "secret") return yield* finish(503, "secret_invalid", notConfigured, { messageId });
      const signatures = (request.headers.get("svix-signature") ?? "").split(" ").filter((entry) => entry.length > 0).length;
      const timestamp = Number(request.headers.get("svix-timestamp") ?? "");
      const skewSeconds = Number.isFinite(timestamp) && timestamp > 0 ? Math.round(nowMs / 1000 - timestamp) : -1;
      return yield* finish(401, check.reason, { _tag: "Unauthorized", message: "Invalid webhook signature" }, { messageId, signatures, skewSeconds });
    }
    const envelope = Schema.decodeUnknownOption(Schema.parseJson(Envelope))(body);
    if (Option.isNone(envelope)) return yield* finish(400, "body_shape", { _tag: "BadRequest", message: "Malformed webhook body" }, { messageId });
    const type = envelope.value.type;
    const eventType = type.slice(0, 64);
    if (!ACTED_ON.has(type)) return yield* finish(200, "ignored", { ok: true, ignored: type }, { messageId, eventType });
    const decoded = decodeEvent(type, envelope.value.data);
    if (Option.isNone(decoded)) return yield* finish(400, "data_shape", { _tag: "BadRequest", message: `Malformed ${type} data` }, { messageId, eventType });
    const event = decoded.value;
    const deliveries = yield* WebhookDeliveryStore;
    const seen = yield* deliveries.processed(check.messageId).pipe(Effect.orElseSucceed(() => false));
    if (seen) return yield* finish(200, "duplicate", { ok: true, duplicate: true }, { messageId, eventType, outcome: "duplicate" });
    const firstSeen = yield* Effect.either(deliveries.firstSeen(check.messageId, new Date(nowMs)));
    // Fails while migration 0008 (stack_webhook_events) is not applied or not granted.
    if (firstSeen._tag === "Left") return yield* finish(503, "first_seen_store", retry, { messageId, eventType });
    const eventAt = firstSeen.right;
    const result = yield* Effect.either(
      event.kind === "membership" ? revokeMemberDevices(event.tenantId, event.userId, eventAt) : revokeDeletedUser(event.userId, event.teams, eventAt),
    );
    if (result._tag === "Left") return yield* finish(503, "revocation", retry, { messageId, eventType, error: result.left._tag });
    const at = new Date(yield* Clock.currentTimeMillis);
    const recorded = yield* Effect.either(
      deliveries.record({ messageId: check.messageId, eventType: type, tenantId: event.tenantId, userId: event.userId, processedAt: at }),
    );
    // The revocation is done; an unrecorded delivery only means a retry repeats the (idempotent) work.
    const done = result.right;
    return yield* finish(200, "processed", { ok: true, ...done }, {
      messageId,
      eventType,
      outcome: "revoked",
      devicesRevoked: done.devicesRevoked,
      meshesReapplied: done.meshesReapplied,
      ...(event.tenantId === null ? {} : { tenantId: event.tenantId }),
      recorded: recorded._tag === "Right",
      eventAgeMs: at.getTime() - eventAt.getTime(),
    });
  });
