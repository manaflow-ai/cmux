/**
 * Identity tables of mesh M4 (migrations/0007_cmux_vm_mesh_m4.sql): the shared
 * positive Stack membership cache (cx-0op.7) and the record of processed Stack
 * webhook deliveries (G1, cx-0op.6). Both are keyed by Stack ids and hold no
 * secret.
 */
import { Context, Effect, Layer, Schema } from "effect";
import { MembershipCache, type MembershipCacheService } from "../auth/membership-cache.ts";
import { SqlClient, StoreError } from "./sql.ts";

export interface WebhookDelivery {
  /** The webhook message id (Svix `svix-id`), the same on every retry of one event. */
  readonly messageId: string;
  readonly eventType: string;
  readonly tenantId: string | null;
  readonly userId: string | null;
  readonly processedAt: Date;
}

export interface WebhookDeliveryStoreService {
  /** Whether the message with this id was processed to the end before. */
  readonly processed: (messageId: string) => Effect.Effect<boolean, StoreError>;
  /** Records that the message was processed; a second record of the same id is a no-op. */
  readonly record: (delivery: WebhookDelivery) => Effect.Effect<void, StoreError>;
}

export class WebhookDeliveryStore extends Context.Tag("cmux-vm/WebhookDeliveryStore")<WebhookDeliveryStore, WebhookDeliveryStoreService>() {}

const Count = Schema.Union(Schema.Number, Schema.NumberFromString);
const CountRow = Schema.Struct({ n: Count });
const countOf = (operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(CountRow))(rows).pipe(
    Effect.map((decoded) => decoded[0]?.n ?? 0),
    Effect.mapError((cause) => new StoreError({ operation, cause })),
  );

export const sqlMembershipCacheLayer: Layer.Layer<MembershipCache, never, SqlClient> = Layer.effect(
  MembershipCache,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const service: MembershipCacheService = {
      fresh: (tenantId, userId, since) =>
        sql
          .query(
            "membership.fresh",
            `SELECT count(*)::int AS n FROM cmux_vm.stack_memberships
              WHERE tenant_id = $1 AND user_id = $2 AND member_asked_at > $3::timestamptz
                AND (revoked_at IS NULL OR member_asked_at > revoked_at)`,
            [tenantId, userId, since.toISOString()],
          )
          .pipe(Effect.flatMap(countOf("membership.fresh")), Effect.map((n) => n > 0)),
      rememberMember: (tenantId, userId, askedAt) =>
        sql
          .query(
            "membership.remember",
            `INSERT INTO cmux_vm.stack_memberships AS m (tenant_id, user_id, member_asked_at)
             VALUES ($1, $2, $3::timestamptz)
             ON CONFLICT (tenant_id, user_id) DO UPDATE
               SET member_asked_at = GREATEST(m.member_asked_at, EXCLUDED.member_asked_at)
             WHERE m.revoked_at IS NULL OR EXCLUDED.member_asked_at > m.revoked_at`,
            [tenantId, userId, askedAt.toISOString()],
          )
          .pipe(Effect.asVoid),
      revoke: (tenantId, userId, at) =>
        sql
          .query(
            "membership.revoke",
            `INSERT INTO cmux_vm.stack_memberships AS m (tenant_id, user_id, revoked_at)
             VALUES ($1, $2, $3::timestamptz)
             ON CONFLICT (tenant_id, user_id) DO UPDATE
               SET revoked_at = GREATEST(m.revoked_at, EXCLUDED.revoked_at)`,
            [tenantId, userId, at.toISOString()],
          )
          .pipe(Effect.asVoid),
    };
    return service;
  }),
);

export const sqlWebhookDeliveryStoreLayer: Layer.Layer<WebhookDeliveryStore, never, SqlClient> = Layer.effect(
  WebhookDeliveryStore,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const service: WebhookDeliveryStoreService = {
      processed: (messageId) =>
        sql
          .query("webhook.processed", `SELECT count(*)::int AS n FROM cmux_vm.stack_webhook_deliveries WHERE message_id = $1`, [messageId])
          .pipe(Effect.flatMap(countOf("webhook.processed")), Effect.map((n) => n > 0)),
      record: (delivery) =>
        sql
          .query(
            "webhook.record",
            `INSERT INTO cmux_vm.stack_webhook_deliveries (message_id, event_type, tenant_id, user_id, processed_at)
             VALUES ($1, $2, $3, $4, $5::timestamptz)
             ON CONFLICT (message_id) DO NOTHING`,
            [delivery.messageId, delivery.eventType, delivery.tenantId, delivery.userId, delivery.processedAt.toISOString()],
          )
          .pipe(Effect.asVoid),
    };
    return service;
  }),
);

/** Processed deliveries in memory (tests, the live proof server). */
export function makeMemoryWebhookDeliveryStore() {
  const deliveries = new Map<string, WebhookDelivery>();
  const service: WebhookDeliveryStoreService = {
    processed: (messageId) => Effect.sync(() => deliveries.has(messageId)),
    record: (delivery) =>
      Effect.sync(() => {
        if (!deliveries.has(delivery.messageId)) deliveries.set(delivery.messageId, delivery);
      }),
  };
  return { service, layer: Layer.succeed(WebhookDeliveryStore, service), deliveries };
}
