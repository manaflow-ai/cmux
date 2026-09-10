// Retention registry: every table in db/schema.ts declares how its size stays
// bounded. tests/db-retention-registry.test.ts fails the build when a table is
// missing here, when an entry names a table or column that does not exist, or
// when a drain column is not a timestamp. The registry is the contract; the
// generic drain in services/retention/drain.ts executes the `column` entries,
// and the `route` entries point at the table-specific drains.
//
// Background: with no retention, cloud_vm_usage_events reached 35k rows in four
// months (96% per-command telemetry), cloud_vm_leases held 11k rows that were
// all expired, and iroh_registration_challenges grew to 4.7 GB in 35 hours.

export type RetentionPolicy =
  /** One row per named entity, deleted with it. Grows only with real users. */
  | { readonly kind: "bounded"; readonly by: string }
  /** Rows must never be deleted by any job. */
  | { readonly kind: "permanent"; readonly reason: string }
  /** The generic cron deletes rows whose `column` is older than `days`. */
  | { readonly kind: "drain"; readonly column: string; readonly days: number }
  /** A table-specific job at `route` deletes rows on its own schedule. */
  | { readonly kind: "drain"; readonly route: string };

const IROH_RETENTION = "/api/internal/iroh/retention";
const LEASE_RETENTION = "/api/internal/vm/leases/revoke-expired";

/** Keyed by SQL table name. Keep alphabetical. */
export const TABLE_RETENTION: Readonly<Record<string, RetentionPolicy>> = {
  account_analytics_forward_leases: { kind: "drain", column: "expires_at", days: 7 },
  account_deletion_tombstones: { kind: "permanent", reason: "deleted accounts must stay deleted" },
  account_mutation_leases: { kind: "bounded", by: "user" },
  admin_plan_grants: { kind: "bounded", by: "grant" },
  billing_email_claims: { kind: "bounded", by: "user" },
  billing_email_verification_deliveries: { kind: "drain", column: "created_at", days: 365 },
  cloud_organizations: { kind: "bounded", by: "organization" },
  cloud_vm_access_grant_sessions: { kind: "bounded", by: "access grant" },
  cloud_vm_access_grants: { kind: "bounded", by: "user device" },
  cloud_vm_base_events: { kind: "drain", column: "created_at", days: 365 },
  cloud_vm_base_generations: { kind: "bounded", by: "base" },
  cloud_vm_bases: { kind: "bounded", by: "user" },
  cloud_vm_billing_grants: { kind: "bounded", by: "customer item" },
  cloud_vm_domains: { kind: "bounded", by: "owner hostname" },
  cloud_vm_leases: { kind: "drain", route: LEASE_RETENTION },
  cloud_vm_networks: { kind: "bounded", by: "user provider" },
  cloud_vm_notification_deliveries: { kind: "bounded", by: "notification event (cascade)" },
  cloud_vm_notification_events: { kind: "drain", column: "expires_at", days: 30 },
  cloud_vm_publication_auth_codes: { kind: "drain", column: "expires_at", days: 7 },
  cloud_vm_publication_auth_transactions: { kind: "drain", column: "expires_at", days: 7 },
  cloud_vm_publication_email_grants: { kind: "bounded", by: "publication" },
  cloud_vm_publication_provider_configs: { kind: "bounded", by: "provider" },
  cloud_vm_publication_sessions: { kind: "drain", column: "expires_at", days: 30 },
  cloud_vm_publication_vm_guards: { kind: "bounded", by: "vm" },
  cloud_vm_publications: { kind: "bounded", by: "vm hostname" },
  cloud_vm_sessions: { kind: "drain", column: "closed_at", days: 90 },
  cloud_vm_tunnel_enrollment_locks: { kind: "drain", column: "expires_at", days: 7 },
  cloud_vm_tunnels: { kind: "bounded", by: "user device purpose" },
  cloud_vm_usage_events: { kind: "drain", column: "created_at", days: 365 },
  cloud_vms: { kind: "bounded", by: "user (destroyed rows kept as the billing trail)" },
  coderouter_accounts: { kind: "bounded", by: "team provider" },
  coderouter_claude_accounts: { kind: "bounded", by: "team" },
  coderouter_credentials: { kind: "bounded", by: "account" },
  coderouter_route_tokens: { kind: "drain", column: "expires_at", days: 30 },
  coderouter_session_accounts: { kind: "bounded", by: "team session" },
  coderouter_vault_leases: { kind: "drain", column: "expires_at", days: 7 },
  device_app_instances: { kind: "bounded", by: "device tag" },
  device_tokens: { kind: "bounded", by: "device bundle" },
  devices: { kind: "bounded", by: "user device" },
  iroh_account_security_states: { kind: "bounded", by: "user" },
  iroh_endpoint_bindings: { kind: "drain", route: IROH_RETENTION },
  iroh_pair_grant_issuances: { kind: "drain", route: IROH_RETENTION },
  iroh_registration_challenges: { kind: "drain", route: IROH_RETENTION },
  iroh_relay_catalog_state: { kind: "bounded", by: "singleton" },
  iroh_relay_preferences: { kind: "bounded", by: "account" },
  iroh_relay_token_issuances: { kind: "drain", route: IROH_RETENTION },
  notification_send_events: { kind: "drain", column: "expires_at", days: 30 },
  pro_welcome_fulfillments: { kind: "bounded", by: "checkout session" },
  rate_limit_alert_reports: { kind: "bounded", by: "alert key" },
  stack_identity_snapshots: { kind: "bounded", by: "user" },
  stripe_customers: { kind: "bounded", by: "customer" },
  stripe_subscriptions: { kind: "bounded", by: "subscription" },
  stripe_webhook_events: { kind: "drain", column: "created_at", days: 180 },
  subrouter_tenants: { kind: "bounded", by: "team" },
  vault_cli_auth_requests: { kind: "drain", column: "expires_at", days: 7 },
  vault_sessions: { kind: "bounded", by: "user agent session" },
  vault_snapshots: { kind: "bounded", by: "session" },
  vault_upload_grants: { kind: "drain", column: "expires_at", days: 30 },
  vault_upload_tombstones: { kind: "drain", column: "expires_at", days: 30 },
};

export type ColumnDrain = {
  readonly table: string;
  readonly column: string;
  readonly days: number;
};

/** The entries the generic cron executes, in registry order. */
export function columnDrains(registry: Readonly<Record<string, RetentionPolicy>> = TABLE_RETENTION): readonly ColumnDrain[] {
  const drains: ColumnDrain[] = [];
  for (const [table, policy] of Object.entries(registry)) {
    if (policy.kind === "drain" && "column" in policy) {
      drains.push({ table, column: policy.column, days: policy.days });
    }
  }
  return drains;
}
