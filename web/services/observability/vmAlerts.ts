import { and, count, eq, gte, inArray, isNull, isNotNull, lt, sql } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { after } from "next/server";
import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import { cloudDb } from "../../db/client";
import { cloudVmAlertStates, cloudVmLeases, cloudVms, cloudVmUsageEvents } from "../../db/schema";
import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";
import { reportError } from "./report";

const CREATE_FAILURE_EVENT_TYPES = ["vm.create.failed", "vm.base.create.failed"] as const;
const DROPPED_ALERT_REPORT_TIMEOUT_MS = 2_000;
const VM_ALERT_REMINDER_WINDOW_MS = 24 * 60 * 60 * 1_000;
const VM_ALERT_DELIVERY_LEASE_MS = 5 * 60 * 1_000;
const VM_ALERT_SAMPLE_LIMIT = 25;
// The cron runs every five minutes. A daily bucket gives operators a reminder
// without creating a new PostHog event for every tick of a persistent outage.
const DROPPED_ALERT_DEDUPE_WINDOW_MS = 24 * 60 * 60 * 1_000;

export type VmAlertCheckSummary = {
  readonly triggered: boolean;
  readonly count: number;
};

export type VmAlertSummary = {
  readonly createFailures: VmAlertCheckSummary;
  readonly stuckProvisioning: VmAlertCheckSummary;
  readonly expiredUnrevokedLeases: VmAlertCheckSummary;
  /**
   * Whether a Slack sink exists at all, and how many triggered alerts were
   * dropped for lack of one during this run. Surfaced in the cron response so
   * an unconfigured production deployment is visible instead of a silent 200.
   */
  readonly alertSink: {
    readonly configured: boolean;
    readonly droppedAlerts: number;
  };
};

export type VmAlertStateStore = {
  readonly claim: (input: AlertInput, now: Date) => Promise<string | null>;
  readonly acknowledge: (key: string, leaseId: string, now: Date) => Promise<void>;
  readonly clear: (key: string, now: Date) => Promise<void>;
};

type SendAlert = (input: AlertInput) => Promise<AlertResult>;

export async function runVmAlertChecks(options: {
  readonly db?: ReturnType<typeof cloudDb>;
  readonly env?: Record<string, string | undefined>;
  readonly now?: Date;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: SendAlert;
  readonly alertStateStore?: VmAlertStateStore;
} = {}): Promise<VmAlertSummary> {
  const db = options.db ?? cloudDb();
  const env = options.env ?? process.env;
  const now = options.now ?? new Date();
  const rawSend = options.sendAlert ?? ((input) => sendAlert(input, { fetch: options.fetch, env }));
  const alertStateStore = options.alertStateStore ?? durableVmAlertStateStore(db);
  const alertsConfigured = Boolean(env.CMUX_ALERTS_SLACK_WEBHOOK_URL?.trim());
  const droppedAlerts: AlertInput[] = [];
  const send: SendAlert = async (input) => {
    const result = await rawSend(input);
    // `configured: false` means the alert had no sink: it fired and went
    // nowhere. Track it so the unconfigured state is loud exactly when it
    // swallowed a real incident signal.
    if (result.configured === false) droppedAlerts.push(input);
    return result;
  };

  const createFailureThreshold = positiveIntegerEnv(env.CMUX_VM_ALERT_CREATE_FAILURES_15M, 3);
  const expiredLeaseThreshold = positiveIntegerEnv(env.CMUX_VM_ALERT_EXPIRED_LEASES, 50);
  const createFailureSince = new Date(now.getTime() - 15 * 60 * 1000);
  const stuckProvisioningBefore = new Date(now.getTime() - 20 * 60 * 1000);

  const createFailures = await countCreateFailures(db, createFailureSince);
  const stuckProvisioning = await listStuckProvisioningVms(db, stuckProvisioningBefore);
  const expiredLeases = await listExpiredUnrevokedLeases(db, now);

  const triggeredAlerts: AlertInput[] = [];
  if (createFailures.count >= createFailureThreshold) {
    triggeredAlerts.push({
      key: "vm-create-failure-spike",
      title: "Cloud VM create failures spiked",
      body: [
        `${createFailures.count} create failures in the last 15 minutes.`,
        `Threshold: ${createFailureThreshold}.`,
        `Providers: ${createFailures.providers.length ? createFailures.providers.join(", ") : "unknown"}.`,
        `VM ids and ages: ${createFailures.samples.length
          ? createFailures.samples.map((sample) => `${sample.vmId} (${formatAge(sample.createdAt, now)})`).join(", ")
          : "unknown"}.`,
      ].join(" "),
      severity: "critical",
    });
  }

  if (stuckProvisioning.length > 0) {
    triggeredAlerts.push({
      key: "vm-stuck-provisioning",
      title: "Cloud VMs stuck provisioning",
      body: [
        `${stuckProvisioning.length} provisioning VM(s) are older than 20 minutes.`,
        `VM ids and ages: ${stuckProvisioning.map((row) => `${row.id} (${formatAge(row.createdAt, now)})`).join(", ")}.`,
      ].join(" "),
      severity: "warning",
    });
  }

  if (expiredLeases.count > expiredLeaseThreshold) {
    triggeredAlerts.push({
      key: "vm-expired-unrevoked-leases",
      title: "Cloud VM leases expired but not revoked",
      body: [
        `${expiredLeases.count} expired identity lease(s) still have revokedAt unset. Threshold: ${expiredLeaseThreshold}.`,
        `Lease ids and ages: ${expiredLeases.samples.map((row) => `${row.id} (${formatAge(row.expiresAt, now)} past expiry)`).join(", ")}.`,
      ].join(" "),
      severity: "warning",
    });
  }

  const triggeredKeys = new Set(triggeredAlerts.map((alert) => alert.key));
  for (const key of [
    "vm-create-failure-spike",
    "vm-stuck-provisioning",
    "vm-expired-unrevoked-leases",
  ]) {
    if (!triggeredKeys.has(key)) await clearAlertState(alertStateStore, key, now);
  }
  for (const alert of triggeredAlerts) {
    const claim = await claimAlertDelivery(alertStateStore, alert, now);
    if (!claim) continue;
    const result = await send(alert);
    if (claim.durable && result.sent) {
      await acknowledgeAlertDelivery(alertStateStore, alert.key, claim.leaseId, now);
    }
  }

  if (droppedAlerts.length > 0) {
    // reportDroppedVmAlerts bounds its capture task; await it so this cron
    // cannot finish before the unconfigured-alert signal is handed off.
    await reportDroppedVmAlerts(droppedAlerts, { env, fetch: options.fetch, now });
  }

  return {
    createFailures: {
      triggered: createFailures.count >= createFailureThreshold,
      count: createFailures.count,
    },
    stuckProvisioning: {
      triggered: stuckProvisioning.length > 0,
      count: stuckProvisioning.length,
    },
    expiredUnrevokedLeases: {
      triggered: expiredLeases.count > expiredLeaseThreshold,
      count: expiredLeases.count,
    },
    alertSink: {
      configured: alertsConfigured,
      droppedAlerts: droppedAlerts.length,
    },
  };
}

/**
 * Operator-fault leg for alerts that fired with no Slack sink configured.
 * Two sinks so at least one is watched: a scrubbed structured error in the
 * runtime logs (plus Sentry when a DSN exists), and a PostHog
 * `cloud_vm_alert_dropped` event insights and alerts can key on. Emits in
 * production only, so dev and preview stay quiet with no webhook set; the
 * daily env audit covers the config gap on quiet days.
 */
export async function reportDroppedVmAlerts(
  alerts: readonly AlertInput[],
  options: {
    readonly env?: Record<string, string | undefined>;
    readonly fetch?: AlertFetch;
    readonly now?: Date;
  } = {},
): Promise<void> {
  const env = options.env ?? process.env;
  if (env.VERCEL_ENV !== "production" && env.CMUX_ALERTS_REPORT_FORCE !== "1") return;
  const keys = [...new Set(alerts.map((alert) => alert.key))];
  if (keys.length === 0) return;
  const now = options.now ?? new Date();
  const dedupeBucket = Math.floor(now.getTime() / DROPPED_ALERT_DEDUPE_WINDOW_MS);
  reportError(
    new Error(`cloud VM alerts fired with no Slack sink configured: ${keys.join(", ")}`),
    {
      subsystem: "cloud_vm_alerts",
      code: "alerts_unconfigured",
      droppedAlerts: keys,
    },
    { fingerprint: ["cmux-vm-alerts", "alerts_unconfigured"] },
  );
  const fetchImpl = options.fetch ?? fetch;
  const captureTask = Promise.all(keys.map((key) => {
    const body = JSON.stringify({
      api_key: POSTHOG_PROJECT_KEY,
      event: "cloud_vm_alert_dropped",
      distinct_id: "cmux-vm-alerts",
      properties: {
        alert_key: key,
        alert_keys: [key],
        alert_count: 1,
        operator_fault: true,
        schema_version: 1,
        // PostHog deduplicates matching distinct_id/$insert_id pairs. The
        // bucket keeps one persistent alert from creating an event every five
        // minutes while avoiding process-local state in serverless workers.
        $insert_id: droppedAlertInsertId(key, dedupeBucket),
        $geoip_disable: true,
      },
      timestamp: now.toISOString(),
    });
    return Promise.resolve()
      .then(() => fetchImpl(`${POSTHOG_HOST}/capture/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        signal: AbortSignal.timeout(DROPPED_ALERT_REPORT_TIMEOUT_MS),
      }))
      .then(() => undefined)
      .catch(() => undefined);
  })).then(() => undefined);
  const boundedCaptureTask = waitForBoundedTask(
    captureTask,
    DROPPED_ALERT_REPORT_TIMEOUT_MS,
  );
  try {
    // Keep the request alive on Vercel while also returning the promise to the
    // cron caller. The fallback is needed for tests and non-request invocations
    // where Next has no after() context.
    after(boundedCaptureTask);
  } catch {
    // The caller still awaits boundedCaptureTask below.
  }
  await boundedCaptureTask;
}

/** Builds the deterministic PostHog identity for one alert and one day. */
function droppedAlertInsertId(key: string, bucket: number): string {
  return `cloud-vm-alert-dropped:${encodeURIComponent(key)}:${bucket}`;
}

/** Waits for telemetry briefly, then lets the alert check complete. */
async function waitForBoundedTask(
  task: Promise<void>,
  timeoutMs: number,
): Promise<void> {
  const timeoutSignal = AbortSignal.timeout(timeoutMs);
  const timeoutTask = new Promise<void>((resolve) => {
    if (timeoutSignal.aborted) {
      resolve();
      return;
    }
    timeoutSignal.addEventListener("abort", () => resolve(), { once: true });
  });
  try {
    await Promise.race([task, timeoutTask]);
  } catch {
    // Telemetry must never make the alert checks fail.
  }
}

async function countCreateFailures(
  db: ReturnType<typeof cloudDb>,
  since: Date,
): Promise<{
  readonly count: number;
  readonly providers: string[];
  readonly samples: Array<{ readonly vmId: string; readonly createdAt: Date }>;
}> {
  const rows = await db
    .select({
      total: count(),
      providers: sql<string[]>`array_remove(array_agg(distinct ${cloudVmUsageEvents.provider}), null)`,
      failureSamples: sql<unknown>`coalesce((
        select json_agg(json_build_object('vmId', sample.vm_id::text, 'createdAt', sample.created_at)
          order by sample.created_at desc)
        from (
          select ${cloudVmUsageEvents.vmId} as vm_id, min(${cloudVmUsageEvents.createdAt}) as created_at
          from ${cloudVmUsageEvents}
          where ${inArray(cloudVmUsageEvents.eventType, [...CREATE_FAILURE_EVENT_TYPES])}
            and ${gte(cloudVmUsageEvents.createdAt, since)}
            and coalesce(${cloudVmUsageEvents.metadata}->>'operation', '') <> 'create_abandoned'
            and ${cloudVmUsageEvents.vmId} is not null
          group by ${cloudVmUsageEvents.vmId}
          order by min(${cloudVmUsageEvents.createdAt}) desc
          limit ${VM_ALERT_SAMPLE_LIMIT}
        ) as sample
      ), '[]'::json)`,
    })
    .from(cloudVmUsageEvents)
    .where(and(
      inArray(cloudVmUsageEvents.eventType, [...CREATE_FAILURE_EVENT_TYPES]),
      gte(cloudVmUsageEvents.createdAt, since),
      sql`coalesce(${cloudVmUsageEvents.metadata}->>'operation', '') <> 'create_abandoned'`,
    ));
  const row = rows[0];
  return {
    count: Number(row?.total ?? 0),
    providers: Array.isArray(row?.providers) ? row.providers : [],
    samples: parseFailureSamples(row?.failureSamples),
  };
}

function parseFailureSamples(value: unknown): Array<{ readonly vmId: string; readonly createdAt: Date }> {
  if (!Array.isArray(value)) return [];
  return value.flatMap((sample) => {
    if (!sample || typeof sample !== "object") return [];
    const vmId = (sample as { vmId?: unknown }).vmId;
    const createdAt = new Date(String((sample as { createdAt?: unknown }).createdAt ?? ""));
    return typeof vmId === "string" && vmId.length > 0 && Number.isFinite(createdAt.getTime())
      ? [{ vmId, createdAt }]
      : [];
  });
}

async function listStuckProvisioningVms(
  db: ReturnType<typeof cloudDb>,
  before: Date,
): Promise<Array<{ id: string; createdAt: Date; updatedAt: Date }>> {
  return db
    .select({ id: cloudVms.id, createdAt: cloudVms.createdAt, updatedAt: cloudVms.updatedAt })
    .from(cloudVms)
    .where(and(eq(cloudVms.status, "provisioning"), lt(cloudVms.createdAt, before)))
    .limit(VM_ALERT_SAMPLE_LIMIT);
}

async function listExpiredUnrevokedLeases(
  db: ReturnType<typeof cloudDb>,
  now: Date,
): Promise<{
  readonly count: number;
  readonly samples: Array<{ readonly id: string; readonly expiresAt: Date }>;
}> {
  const [countRow] = await db
    .select({ total: count() })
    .from(cloudVmLeases)
    .where(and(
      lt(cloudVmLeases.expiresAt, now),
      isNull(cloudVmLeases.revokedAt),
      isNotNull(cloudVmLeases.providerIdentityHandle),
      sql`trim(${cloudVmLeases.providerIdentityHandle}) <> ''`,
    ));
  const samples = await db
    .select({ id: cloudVmLeases.id, expiresAt: cloudVmLeases.expiresAt })
    .from(cloudVmLeases)
    .where(and(
      lt(cloudVmLeases.expiresAt, now),
      isNull(cloudVmLeases.revokedAt),
      isNotNull(cloudVmLeases.providerIdentityHandle),
      sql`trim(${cloudVmLeases.providerIdentityHandle}) <> ''`,
    ))
    .limit(VM_ALERT_SAMPLE_LIMIT);
  return { count: Number(countRow?.total ?? 0), samples };
}

function formatAge(start: Date, now: Date): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - start.getTime()) / 60_000));
  if (minutes >= 24 * 60) return `${Math.floor(minutes / (24 * 60))}d old`;
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h old`;
  return `${minutes}m old`;
}

/**
 * Postgres-backed alert dedupe keyed by alert key: a claim succeeds when the
 * alert is new, escalated, or its last delivery is older than the 24-hour
 * reminder window. Shared by every cron alert that must not repeat each run.
 */
export function durableVmAlertStateStore(db: ReturnType<typeof cloudDb>): VmAlertStateStore {
  return {
    claim: async (input, now) => {
      const reminderBefore = new Date(now.getTime() - VM_ALERT_REMINDER_WINDOW_MS);
      const leaseId = randomUUID();
      const leaseUntil = new Date(now.getTime() + VM_ALERT_DELIVERY_LEASE_MS);
      const rows = await db.execute(sql`
        insert into "cloud_vm_alert_states"
          ("alert_key", "active", "severity", "delivery_lease_id", "delivery_lease_until", "updated_at")
        values (
          ${input.key}, true, ${input.severity}, ${leaseId},
          ${leaseUntil.toISOString()}::timestamptz, ${now.toISOString()}::timestamptz
        )
        on conflict ("alert_key") do update set
          "active" = true,
          "severity" = excluded."severity",
          "delivery_lease_id" = excluded."delivery_lease_id",
          "delivery_lease_until" = excluded."delivery_lease_until",
          "updated_at" = excluded."updated_at"
        where (
          "cloud_vm_alert_states"."active" = false
          or (${input.severity} = 'critical' and "cloud_vm_alert_states"."severity" <> 'critical')
          or "cloud_vm_alert_states"."last_sent_at" is null
          or "cloud_vm_alert_states"."last_sent_at" < ${reminderBefore.toISOString()}::timestamptz
        )
          and (
            "cloud_vm_alert_states"."delivery_lease_until" is null
            or "cloud_vm_alert_states"."delivery_lease_until" < ${now.toISOString()}::timestamptz
            or (${input.severity} = 'critical' and "cloud_vm_alert_states"."severity" <> 'critical')
          )
        returning "delivery_lease_id"
      `);
      return rows[0]?.delivery_lease_id === leaseId ? leaseId : null;
    },
    acknowledge: async (key, leaseId, now) => {
      await db
        .update(cloudVmAlertStates)
        .set({
          lastSentAt: now,
          deliveryLeaseId: null,
          deliveryLeaseUntil: null,
          updatedAt: now,
        })
        .where(and(
          eq(cloudVmAlertStates.alertKey, key),
          eq(cloudVmAlertStates.deliveryLeaseId, leaseId),
        ));
    },
    clear: async (key, now) => {
      await db
        .update(cloudVmAlertStates)
        .set({ active: false, deliveryLeaseId: null, deliveryLeaseUntil: null, updatedAt: now })
        .where(eq(cloudVmAlertStates.alertKey, key));
    },
  };
}

async function claimAlertDelivery(
  store: VmAlertStateStore,
  input: AlertInput,
  now: Date,
): Promise<{ readonly leaseId: string; readonly durable: true } | { readonly leaseId: null; readonly durable: false } | null> {
  try {
    const leaseId = await store.claim(input, now);
    return leaseId ? { leaseId, durable: true } : null;
  } catch (error) {
    // Alert delivery must fail open when the dedupe ledger is unavailable; a
    // database outage should not hide a real operational incident.
    console.error("vm.alerts.dedupe_unavailable", {
      alertKey: input.key,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    return { leaseId: null, durable: false };
  }
}

async function acknowledgeAlertDelivery(
  store: VmAlertStateStore,
  key: string,
  leaseId: string,
  now: Date,
): Promise<void> {
  try {
    await store.acknowledge(key, leaseId, now);
  } catch (error) {
    console.error("vm.alerts.acknowledge_failed", {
      alertKey: key,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
  }
}

async function clearAlertState(store: VmAlertStateStore, key: string, now: Date): Promise<void> {
  try {
    await store.clear(key, now);
  } catch (error) {
    console.error("vm.alerts.state_clear_failed", {
      alertKey: key,
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
  }
}

function positiveIntegerEnv(value: string | undefined, fallback: number): number {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return fallback;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
