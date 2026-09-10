import { sql } from "drizzle-orm";
import { check, index, integer, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

/** Typed SQLite schema owned by one AccountControlPlane Durable Object. */
export const accountStorageUsage = sqliteTable(
  "account_storage_usage",
  {
    id: integer("id").primaryKey(),
    payloadBytes: integer("payload_bytes").notNull(),
    records: integer("records").notNull(),
    liveBindings: integer("live_bindings").notNull(),
  },
  (table) => [
    check("account_storage_usage_id_check", sql`${table.id} = 1`),
    check("account_storage_usage_payload_check", sql`${table.payloadBytes} between 0 and 8388608`),
    check("account_storage_usage_records_check", sql`${table.records} between 0 and 4096`),
    check("account_storage_usage_bindings_check", sql`${table.liveBindings} between 0 and 32`),
  ],
);

const payloadColumns = {
  payload: text("payload").notNull(),
  payloadBytes: integer("payload_bytes").notNull(),
} as const;

export const accountBindings = sqliteTable(
  "account_bindings",
  {
    bindingId: text("binding_id").primaryKey(),
    endpointId: text("endpoint_id").notNull(),
    deviceId: text("device_id").notNull(),
    clientNamespace: text("client_namespace").notNull(),
    platform: text("platform", { enum: ["mac", "ios"] }).notNull(),
    ...payloadColumns,
    lastSeenAt: integer("last_seen_at").notNull(),
    registeredAt: integer("registered_at").notNull(),
    revokedAt: integer("revoked_at"),
    tombstoneExpiresAt: integer("tombstone_expires_at"),
  },
  (table) => [
    uniqueIndex("account_bindings_endpoint_live").on(table.endpointId).where(sql`${table.revokedAt} is null`),
    index("account_bindings_live_expiry").on(table.lastSeenAt).where(sql`${table.revokedAt} is null`),
    index("account_bindings_revoked_expiry").on(table.tombstoneExpiresAt).where(sql`${table.revokedAt} is not null`),
    check("account_bindings_endpoint_check", sql`length(${table.endpointId}) = 64`),
    check("account_bindings_platform_check", sql`${table.platform} in ('mac', 'ios')`),
    check("account_bindings_payload_size_check", sql`${table.payloadBytes} between 0 and 65536`),
    check("account_bindings_revocation_check", sql`(
      (${table.revokedAt} is null and ${table.tombstoneExpiresAt} is null) or
      (${table.revokedAt} is not null and ${table.tombstoneExpiresAt} is not null and
       ${table.tombstoneExpiresAt} >= ${table.revokedAt} + 2592000000)
    )`),
  ],
);

function temporaryTable(name: string, keyName: string) {
  return sqliteTable(name, {
    [keyName]: text(keyName).primaryKey(),
    ...payloadColumns,
    expiresAt: integer("expires_at").notNull(),
  }, (table) => [
    index(`${name}_expiry`).on(table.expiresAt),
    check(`${name}_payload_size_check`, sql`${table.payloadBytes} between 0 and 65536`),
  ]);
}

export const accountChallenges = temporaryTable("account_challenges", "challenge_id");
export const accountPairGrants = temporaryTable("account_pair_grants", "grant_id");
export const accountRelayIssuances = temporaryTable("account_relay_issuances", "issuance_id");

export const accountPreferences = sqliteTable(
  "account_preferences",
  {
    preferenceKey: text("preference_key").primaryKey(),
    ...payloadColumns,
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => [
    check("account_preferences_key_check", sql`${table.preferenceKey} = 'relay'`),
    check("account_preferences_payload_size_check", sql`${table.payloadBytes} between 0 and 65536`),
  ],
);

export const accountMeta = sqliteTable(
  "account_meta",
  {
    key: text("key").primaryKey(),
    value: text("value").notNull(),
  },
  (table) => [
    check("account_meta_key_check", sql`${table.key} in ('route_revision', 'lan_generation', 'revocation_epoch')`),
    check("account_meta_value_check", sql`length(${table.value}) <= 128`),
  ],
);

export const drizzleTransactionProbe = sqliteTable("drizzle_transaction_probe", {
  id: integer("id").primaryKey(),
  value: text("value").notNull(),
});

export const accountDrizzleSchema = {
  accountStorageUsage,
  accountBindings,
  accountChallenges,
  accountPairGrants,
  accountRelayIssuances,
  accountPreferences,
  accountMeta,
  drizzleTransactionProbe,
};

export type AccountBindingInsert = typeof accountBindings.$inferInsert;
export type AccountBindingRow = typeof accountBindings.$inferSelect;
export type AccountChallengeInsert = typeof accountChallenges.$inferInsert;
export type AccountChallengeRow = typeof accountChallenges.$inferSelect;
