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

export const vmProvider = pgEnum("vm_provider", ["e2b", "freestyle"]);

export const vmStatus = pgEnum("vm_status", [
  "provisioning",
  "running",
  "failed",
  "paused",
  "destroyed",
]);

export const vmLeaseKind = pgEnum("vm_lease_kind", ["pty", "rpc", "ssh"]);

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
  },
  (table) => [
    index("cloud_vms_user_status_idx").on(table.userId, table.status),
    index("cloud_vms_billing_team_status_idx").on(table.billingTeamId, table.status),
    uniqueIndex("cloud_vms_user_idempotency_key_unique")
      .on(table.userId, table.idempotencyKey)
      .where(sql`${table.idempotencyKey} is not null`),
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
