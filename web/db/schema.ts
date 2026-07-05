import { sql } from "drizzle-orm";
import {
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";

export const vmProvider = pgEnum("vm_provider", ["e2b", "freestyle", "daytona"]);

export const vmStatus = pgEnum("vm_status", [
  "provisioning",
  "running",
  "failed",
  "paused",
  "destroyed",
]);

export const vmLeaseKind = pgEnum("vm_lease_kind", ["pty", "rpc", "ssh"]);

export const cloudVmSessionStatus = pgEnum("cloud_vm_session_status", [
  "running",
  "detached",
  "exited",
  "closed",
]);

export const cloudVmNotificationSeverity = pgEnum("cloud_vm_notification_severity", [
  "info",
  "success",
  "warning",
  "error",
]);

export const cloudVmNotificationDeliveryStatus = pgEnum("cloud_vm_notification_delivery_status", [
  "pending",
  "sent",
  "failed",
  "read",
  "dismissed",
]);

export const cloudVms = pgTable(
  "cloud_vms",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    userId: text("user_id").notNull(),
    billingTeamId: text("billing_team_id"),
    billingPlanId: text("billing_plan_id"),
    provider: vmProvider("provider").notNull(),
    providerVmId: text("provider_vm_id"),
    imageId: text("image_id").notNull(),
    imageVersion: text("image_version"),
    status: vmStatus("status").notNull().default("provisioning"),
    idempotencyKey: text("idempotency_key"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    destroyedAt: timestamp("destroyed_at", { withTimezone: true }),
    failureCode: text("failure_code"),
    failureMessage: text("failure_message"),
    providerMetadata: jsonb("provider_metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
  },
  (table) => [
    index("cloud_vms_user_status_idx").on(table.userId, table.status),
    index("cloud_vms_billing_team_status_idx").on(table.billingTeamId, table.status),
    uniqueIndex("cloud_vms_billing_team_idempotency_key_unique")
      .on(table.billingTeamId, table.idempotencyKey)
      .where(sql`${table.billingTeamId} is not null and ${table.idempotencyKey} is not null`),
    uniqueIndex("cloud_vms_provider_vm_id_unique")
      .on(table.provider, table.providerVmId)
      .where(sql`${table.providerVmId} is not null`),
  ],
);

export const cloudVmLeases = pgTable(
  "cloud_vm_leases",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    vmId: uuid("vm_id")
      .notNull()
      .references(() => cloudVms.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull(),
    kind: vmLeaseKind("kind").notNull(),
    tokenHash: text("token_hash").notNull(),
    providerIdentityHandle: text("provider_identity_handle"),
    sessionId: text("session_id"),
    transport: text("transport"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    consumedAt: timestamp("consumed_at", { withTimezone: true }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("cloud_vm_leases_vm_kind_idx").on(table.vmId, table.kind),
    index("cloud_vm_leases_identity_idx").on(table.providerIdentityHandle),
    index("cloud_vm_leases_user_expires_idx").on(table.userId, table.expiresAt),
    uniqueIndex("cloud_vm_leases_token_hash_unique").on(table.tokenHash),
  ],
);

export const cloudVmSessions = pgTable(
  "cloud_vm_sessions",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    vmId: uuid("vm_id")
      .notNull()
      .references(() => cloudVms.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull(),
    providerSessionId: text("provider_session_id").notNull(),
    title: text("title"),
    kind: text("kind").notNull().default("terminal"),
    status: cloudVmSessionStatus("status").notNull().default("running"),
    attachmentCount: integer("attachment_count").notNull().default(0),
    effectiveCols: integer("effective_cols"),
    effectiveRows: integer("effective_rows"),
    lastKnownCols: integer("last_known_cols"),
    lastKnownRows: integer("last_known_rows"),
    scrollbackBytes: integer("scrollback_bytes").notNull().default(0),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    lastAttachedAt: timestamp("last_attached_at", { withTimezone: true }),
    exitedAt: timestamp("exited_at", { withTimezone: true }),
    closedAt: timestamp("closed_at", { withTimezone: true }),
  },
  (table) => [
    uniqueIndex("cloud_vm_sessions_vm_provider_session_unique")
      .on(table.vmId, table.providerSessionId),
    index("cloud_vm_sessions_user_status_updated_idx")
      .on(table.userId, table.status, table.updatedAt),
    index("cloud_vm_sessions_vm_updated_idx").on(table.vmId, table.updatedAt),
  ],
);

export const cloudVmUsageEvents = pgTable(
  "cloud_vm_usage_events",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    userId: text("user_id").notNull(),
    billingTeamId: text("billing_team_id"),
    billingPlanId: text("billing_plan_id"),
    vmId: uuid("vm_id").references(() => cloudVms.id, { onDelete: "set null" }),
    eventType: text("event_type").notNull(),
    provider: vmProvider("provider"),
    imageId: text("image_id"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("cloud_vm_usage_events_user_created_idx").on(table.userId, table.createdAt),
    index("cloud_vm_usage_events_billing_team_created_idx").on(table.billingTeamId, table.createdAt),
    index("cloud_vm_usage_events_vm_created_idx").on(table.vmId, table.createdAt),
    index("cloud_vm_usage_events_type_created_idx").on(table.eventType, table.createdAt),
  ],
);

export const cloudVmProbeState = pgTable(
  "cloud_vm_probe_state",
  {
    key: text("key").primaryKey(),
    lastRunAt: timestamp("last_run_at", { withTimezone: true }),
    lastSuccessAt: timestamp("last_success_at", { withTimezone: true }),
    consecutiveFailures: integer("consecutive_failures").notNull().default(0),
    lastErrorCode: text("last_error_code"),
    lastErrorMessage: text("last_error_message"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
);

export const cloudVmBases = pgTable(
  "cloud_vm_bases",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    scopeType: text("scope_type").notNull(),
    scopeId: text("scope_id").notNull(),
    name: text("name").notNull().default("base"),
    activeGeneration: integer("active_generation").notNull().default(0),
    activeVmId: uuid("active_vm_id").references(() => cloudVms.id, { onDelete: "set null" }),
    activeProvider: vmProvider("active_provider"),
    activeProviderVmId: text("active_provider_vm_id"),
    state: text("state").notNull().default("creating"),
    createdByUserId: text("created_by_user_id").notNull(),
    lastOpenedByUserId: text("last_opened_by_user_id"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("cloud_vm_bases_scope_name_unique").on(table.scopeType, table.scopeId, table.name),
    index("cloud_vm_bases_active_vm_idx").on(table.activeVmId),
    index("cloud_vm_bases_provider_vm_idx").on(table.activeProvider, table.activeProviderVmId),
  ],
);

export const cloudVmBaseGenerations = pgTable(
  "cloud_vm_base_generations",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    baseId: uuid("base_id")
      .notNull()
      .references(() => cloudVmBases.id, { onDelete: "cascade" }),
    generation: integer("generation").notNull(),
    vmId: uuid("vm_id").references(() => cloudVms.id, { onDelete: "set null" }),
    provider: vmProvider("provider"),
    providerVmId: text("provider_vm_id"),
    state: text("state").notNull().default("creating"),
    createdByUserId: text("created_by_user_id").notNull(),
    retainedAt: timestamp("retained_at", { withTimezone: true }),
    deletedAt: timestamp("deleted_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("cloud_vm_base_generations_base_generation_unique").on(table.baseId, table.generation),
    index("cloud_vm_base_generations_vm_idx").on(table.vmId),
    index("cloud_vm_base_generations_provider_vm_idx").on(table.provider, table.providerVmId),
  ],
);

export const cloudVmBaseEvents = pgTable(
  "cloud_vm_base_events",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    baseId: uuid("base_id")
      .notNull()
      .references(() => cloudVmBases.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull(),
    eventType: text("event_type").notNull(),
    oldGeneration: integer("old_generation"),
    newGeneration: integer("new_generation"),
    oldVmId: uuid("old_vm_id").references(() => cloudVms.id, { onDelete: "set null" }),
    newVmId: uuid("new_vm_id").references(() => cloudVms.id, { onDelete: "set null" }),
    oldProviderVmId: text("old_provider_vm_id"),
    newProviderVmId: text("new_provider_vm_id"),
    reason: text("reason"),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("cloud_vm_base_events_base_created_idx").on(table.baseId, table.createdAt),
    index("cloud_vm_base_events_user_created_idx").on(table.userId, table.createdAt),
  ],
);

/**
 * APNs device tokens for iOS push notifications. A row exists only after the
 * user explicitly opts in on their device (the feature is off by default), so
 * the mere presence of a row for a user means "this user wants phone pushes".
 * Keyed unique by `deviceToken` so a device re-registering (e.g. after an
 * account switch) updates its `userId` instead of duplicating.
 */
export const deviceTokens = pgTable(
  "device_tokens",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    userId: text("user_id").notNull(),
    deviceToken: text("device_token").notNull(),
    platform: text("platform").notNull().default("ios"),
    // The APNs topic the token belongs to (the iOS bundle id, which varies by
    // build: dev.cmux.ios.<tag>, dev.cmux.app.beta, com.cmuxterm.app).
    bundleId: text("bundle_id").notNull(),
    // "sandbox" for development builds, "production" for TestFlight/App Store —
    // selects which APNs host the sender uses.
    environment: text("environment").notNull().default("production"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("device_tokens_user_idx").on(table.userId),
    uniqueIndex("device_tokens_device_token_unique").on(table.deviceToken),
  ],
);

export const notificationSendEvents = pgTable(
  "notification_send_events",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    userId: text("user_id").notNull(),
    deviceCount: integer("device_count").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("notification_send_events_user_created_idx").on(table.userId, table.createdAt),
  ],
);

export const cloudVmBillingGrants = pgTable(
  "cloud_vm_billing_grants",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    billingCustomerType: text("billing_customer_type").notNull(),
    billingCustomerId: text("billing_customer_id").notNull(),
    billingPlanId: text("billing_plan_id").notNull(),
    itemId: text("item_id").notNull(),
    amount: integer("amount").notNull(),
    reason: text("reason").notNull(),
    appliedAt: timestamp("applied_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    index("cloud_vm_billing_grants_customer_created_idx")
      .on(table.billingCustomerType, table.billingCustomerId, table.createdAt),
    uniqueIndex("cloud_vm_billing_grants_customer_item_reason_unique")
      .on(table.billingCustomerType, table.billingCustomerId, table.itemId, table.reason),
  ],
);

/**
 * Device registry — the team-scoped record of which physical machines (Macs /
 * hosts) and their running cmux app instances exist, so a phone can auto-pair
 * on reload instead of re-scanning a QR.
 *
 * Two-level model:
 *   `devices` (a physical machine) -> `deviceAppInstances` (one running cmux
 *   build/tag on that machine).
 *
 * The registry is a best-effort *rendezvous* layer that lets a re-launched
 * phone look up the current routes for the Mac it last paired with. It is NOT
 * an authority on pairing: a phone keeps its own local paired-Mac store and
 * falls back to it if the registry is unreachable, so pairing survives the
 * cloud registry being down.
 *
 * Device identity is a cmux-GENERATED persisted UUID (see Mac
 * `MobileHostIdentity.deviceID()` / iOS `MobileDeviceIdentity`), NOT
 * IOPlatformUUID. It is cross-platform, survives relaunch, and is
 * user-renamable via `displayName`.
 */
export const devices = pgTable(
  "devices",
  {
    // Surrogate primary key for the team-scoped device row.
    id: uuid("id").defaultRandom().primaryKey(),
    // Stack team that owns this device row. All registry reads/writes are
    // scoped to a team the caller is a verified member of (`X-Cmux-Team-Id`).
    teamId: text("team_id").notNull(),
    // The cmux-generated persisted UUID supplied by the device. It is the
    // device's stable, global identity (mirrors Mac `MobileHostIdentity` / iOS
    // `MobileDeviceIdentity`), but identity is modeled per team: one row per
    // (team, device), so a Mac in two teams registers a row in each and a phone
    // scoped to either team can find it. NOTE (key-pinning phase): a pinned
    // per-device key for revoke attaches per team-device row, which is the
    // correct revoke granularity. P1 stores identity only.
    deviceUuid: uuid("device_uuid").notNull(),
    // Stack user that registered the device (audit / future per-user views).
    userId: text("user_id").notNull(),
    // "mac" | "ios" | "linux" | ... (free-form so new host platforms need no
    // migration). The host that advertises routes is typically "mac".
    platform: text("platform").notNull(),
    // User-renamable label (e.g. the Mac's name). Optional.
    displayName: text("display_name"),
    // Flexible bag for arbitrary metadata (OS version, model, capabilities,
    // and later a pinned key fingerprint). Avoids a migration per new field.
    labels: jsonb("labels").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    lastSeenAt: timestamp("last_seen_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("devices_team_device_uuid_unique").on(table.teamId, table.deviceUuid),
    index("devices_team_last_seen_idx").on(table.teamId, table.lastSeenAt),
    index("devices_team_user_idx").on(table.teamId, table.userId),
  ],
);

/**
 * A running cmux app instance on a device, keyed by `(deviceId, tag)` so each
 * tagged build (`dev.cmux.<tag>`, stable, etc.) on the same machine is its own
 * row. Holds the attach `routes` the phone uses to reconnect; the registry is
 * port-flexible, so the endpoint lives in `routes` jsonb rather than a fixed
 * column. A re-register updates the routes for the same `(deviceId, tag)`.
 */
export const deviceAppInstances = pgTable(
  "device_app_instances",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    deviceId: uuid("device_id")
      .notNull()
      .references(() => devices.id, { onDelete: "cascade" }),
    teamId: text("team_id").notNull(),
    // The cmux build tag this instance is running (e.g. "stable" or a dev tag).
    // Defaults to "default" when the build does not distinguish tags.
    tag: text("tag").notNull().default("default"),
    // Attach routes advertised by this instance, ordered by priority. Shape
    // mirrors the Mac/iOS `CmxAttachRoute` (kind + endpoint + priority), kept as
    // jsonb so the registry stays port- and transport-flexible.
    routes: jsonb("routes").$type<unknown[]>().notNull().default(sql`'[]'::jsonb`),
    labels: jsonb("labels").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    lastSeenAt: timestamp("last_seen_at", { withTimezone: true }).notNull().defaultNow(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("device_app_instances_device_tag_unique").on(table.deviceId, table.tag),
    index("device_app_instances_team_last_seen_idx").on(table.teamId, table.lastSeenAt),
  ],
);

export const cloudVmNotificationEvents = pgTable(
  "cloud_vm_notification_events",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    vmId: uuid("vm_id")
      .notNull()
      .references(() => cloudVms.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull(),
    billingTeamId: text("billing_team_id"),
    providerSessionId: text("provider_session_id"),
    severity: cloudVmNotificationSeverity("severity").notNull().default("info"),
    source: text("source").notNull().default("vm"),
    title: text("title").notNull(),
    body: text("body").notNull(),
    action: jsonb("action").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    metadata: jsonb("metadata").$type<Record<string, unknown>>().notNull().default(sql`'{}'::jsonb`),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp("expires_at", { withTimezone: true }),
  },
  (table) => [
    index("cloud_vm_notification_events_user_created_idx").on(table.userId, table.createdAt),
    index("cloud_vm_notification_events_vm_session_created_idx")
      .on(table.vmId, table.providerSessionId, table.createdAt),
  ],
);

export const cloudVmNotificationDeliveries = pgTable(
  "cloud_vm_notification_deliveries",
  {
    id: uuid("id").defaultRandom().primaryKey(),
    eventId: uuid("event_id")
      .notNull()
      .references(() => cloudVmNotificationEvents.id, { onDelete: "cascade" }),
    userId: text("user_id").notNull(),
    targetKey: text("target_key").notNull(),
    deviceId: uuid("device_id").references(() => devices.id, { onDelete: "set null" }),
    appInstanceId: uuid("app_instance_id").references(() => deviceAppInstances.id, { onDelete: "set null" }),
    channel: text("channel").notNull(),
    status: cloudVmNotificationDeliveryStatus("status").notNull().default("pending"),
    errorCode: text("error_code"),
    errorMessage: text("error_message"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    sentAt: timestamp("sent_at", { withTimezone: true }),
    readAt: timestamp("read_at", { withTimezone: true }),
    dismissedAt: timestamp("dismissed_at", { withTimezone: true }),
  },
  (table) => [
    uniqueIndex("cloud_vm_notification_deliveries_event_channel_target_unique")
      .on(table.eventId, table.channel, table.targetKey),
    index("cloud_vm_notification_deliveries_user_status_created_idx")
      .on(table.userId, table.status, table.createdAt),
    index("cloud_vm_notification_deliveries_event_status_idx")
      .on(table.eventId, table.status),
  ],
);
