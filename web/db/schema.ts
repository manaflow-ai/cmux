import { sql } from "drizzle-orm";
import {
  index,
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
