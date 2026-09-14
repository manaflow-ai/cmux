import {
  integer,
  index,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from "drizzle-orm/sqlite-core";

/** Team-local state. The TeamStore is constructed for one team and checks all identity scopes. */
export const teamMeta = sqliteTable("team_meta", {
  id: integer("id").primaryKey(),
  revision: integer("revision").notNull().default(0),
  schemaVersion: integer("schema_version").notNull().default(1),
});

export const devices = sqliteTable(
  "devices",
  {
    identityKey: text("identity_key").primaryKey(),
    deviceRecordId: text("device_record_id").notNull(),
    environment: text("environment").notNull(),
    projectId: text("project_id").notNull(),
    teamId: text("team_id").notNull(),
    userId: text("user_id").notNull(),
    deviceId: text("device_id").notNull(),
    appNamespace: text("app_namespace").notNull(),
    buildTag: text("build_tag").notNull(),
    endpointId: text("endpoint_id").notNull(),
    identityGeneration: integer("identity_generation").notNull(),
    platform: text("platform").notNull(),
    displayName: text("display_name").notNull(),
    appVersion: text("app_version").notNull(),
    pairingEnabled: integer("pairing_enabled", { mode: "boolean" }).notNull(),
    capabilitiesJson: text("capabilities_json").notNull(),
    relayUrlsJson: text("relay_urls_json").notNull(),
    revoked: integer("revoked", { mode: "boolean" }).notNull().default(false),
    revision: integer("revision").notNull(),
    createdAt: integer("created_at").notNull(),
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => ({
    userIndex: index("devices_user_idx").on(table.userId),
    endpointIndex: uniqueIndex("devices_endpoint_idx").on(table.endpointId),
    teamIndex: index("devices_team_idx").on(table.teamId),
    recordIndex: uniqueIndex("devices_record_idx").on(table.deviceRecordId),
  }),
);

export const pendingChallenges = sqliteTable(
  "pending_challenges",
  {
    identityKey: text("identity_key").primaryKey(),
    challengeId: text("challenge_id").notNull(),
    nonceHash: text("nonce_hash").notNull(),
    payloadHash: text("payload_hash").notNull(),
    expiresAt: integer("expires_at").notNull(),
    issuedAt: integer("issued_at").notNull(),
  },
  (table) => ({
    challengeIndex: uniqueIndex("pending_challenges_id_idx").on(table.challengeId),
  }),
);

export const registrationReceipts = sqliteTable(
  "registration_receipts",
  {
    identityKey: text("identity_key").notNull(),
    requestId: text("request_id").notNull(),
    requestHash: text("request_hash").notNull(),
    deviceJson: text("device_json").notNull(),
    createdAt: integer("created_at").notNull(),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.identityKey] }),
    requestIndex: uniqueIndex("registration_receipts_request_idx").on(table.requestId),
    identityIndex: index("registration_receipts_identity_idx").on(table.identityKey),
  }),
);

export const teamPreferences = sqliteTable("team_preferences", {
  id: integer("id").primaryKey(),
  relayUrlsJson: text("relay_urls_json").notNull(),
  revision: integer("revision").notNull(),
  updatedAt: integer("updated_at").notNull(),
});

export const authorityAudit = sqliteTable(
  "authority_audit",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    eventType: text("event_type").notNull(),
    actorUserId: text("actor_user_id").notNull(),
    targetId: text("target_id").notNull(),
    revision: integer("revision").notNull(),
    createdAt: integer("created_at").notNull(),
    detailJson: text("detail_json").notNull(),
  },
  (table) => ({
    targetIndex: index("authority_audit_target_idx").on(table.targetId, table.createdAt),
  }),
);

export const deviceProofReplays = sqliteTable(
  "device_proof_replays",
  {
    identityKey: text("identity_key").notNull(),
    requestId: text("request_id").notNull(),
    issuedAt: integer("issued_at").notNull(),
    expiresAt: integer("expires_at").notNull(),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.identityKey, table.requestId] }),
    expiryIndex: index("device_proof_replays_expiry_idx").on(table.identityKey, table.expiresAt),
  }),
);

export const permissions = sqliteTable(
  "permissions",
  {
    subjectUserId: text("subject_user_id").notNull(),
    deviceRecordId: text("device_record_id").notNull(),
    connect: integer("connect", { mode: "boolean" }).notNull().default(false),
    manage: integer("manage", { mode: "boolean" }).notNull().default(false),
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.subjectUserId, table.deviceRecordId] }),
    deviceIndex: index("permissions_device_idx").on(table.deviceRecordId),
    subjectIndex: index("permissions_subject_idx").on(table.subjectUserId),
  }),
);

/** Product and request limits are global per verified user within an environment. */
export const userUsage = sqliteTable(
  "user_usage",
  {
    scopeKey: text("scope_key").notNull(),
    userId: text("user_id").notNull(),
    operation: text("operation").notNull(),
    tokens: real("tokens").notNull(),
    refilledAt: integer("refilled_at").notNull(),
    consumed: integer("consumed").notNull().default(0),
  },
  (table) => ({
    pk: primaryKey({ columns: [table.scopeKey, table.userId, table.operation] }),
    userIndex: index("user_usage_user_idx").on(table.scopeKey, table.userId),
  }),
);

export const storageSchema = { teamMeta, devices, pendingChallenges, registrationReceipts, deviceProofReplays, permissions, userUsage, teamPreferences, authorityAudit };

export type StorageSchema = typeof storageSchema;
