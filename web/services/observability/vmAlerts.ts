import { and, count, eq, gte, inArray, isNull, lt, sql } from "drizzle-orm";
import { after } from "next/server";
import { POSTHOG_HOST, POSTHOG_PROJECT_KEY } from "../analytics/iosEventPolicy";
import { cloudDb } from "../../db/client";
import { cloudVmLeases, cloudVms, cloudVmUsageEvents } from "../../db/schema";
import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";
import { reportError } from "./report";

const CREATE_FAILURE_EVENT_TYPES = ["vm.create.failed", "vm.base.create.failed"] as const;
const DROPPED_ALERT_REPORT_TIMEOUT_MS = 2_000;
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

type SendAlert = (input: AlertInput) => Promise<AlertResult>;

export async function runVmAlertChecks(options: {
  readonly db?: ReturnType<typeof cloudDb>;
  readonly env?: Record<string, string | undefined>;
  readonly now?: Date;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: SendAlert;
} = {}): Promise<VmAlertSummary> {
  const db = options.db ?? cloudDb();
  const env = options.env ?? process.env;
  const now = options.now ?? new Date();
  const rawSend = options.sendAlert ?? ((input) => sendAlert(input, { fetch: options.fetch, env }));
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
  const expiredLeaseCount = await countExpiredUnrevokedLeases(db, now);

  if (createFailures.count >= createFailureThreshold) {
    await send({
      key: "vm-create-failure-spike",
      title: "Cloud VM create failures spiked",
      body: [
        `${createFailures.count} create failures in the last 15 minutes.`,
        `Threshold: ${createFailureThreshold}.`,
        `Providers: ${createFailures.providers.length ? createFailures.providers.join(", ") : "unknown"}.`,
      ].join(" "),
      severity: "critical",
    });
  }

  if (stuckProvisioning.length > 0) {
    await send({
      key: "vm-stuck-provisioning",
      title: "Cloud VMs stuck provisioning",
      body: [
        `${stuckProvisioning.length} provisioning VM(s) are older than 20 minutes.`,
        `VM ids: ${stuckProvisioning.map((row) => row.id).join(", ")}.`,
      ].join(" "),
      severity: "warning",
    });
  }

  if (expiredLeaseCount > expiredLeaseThreshold) {
    await send({
      key: "vm-expired-unrevoked-leases",
      title: "Cloud VM leases expired but not revoked",
      body: `${expiredLeaseCount} expired lease(s) still have revokedAt unset. Threshold: ${expiredLeaseThreshold}.`,
      severity: "warning",
    });
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
      triggered: expiredLeaseCount > expiredLeaseThreshold,
      count: expiredLeaseCount,
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
): Promise<{ count: number; providers: string[] }> {
  const rows = await db
    .select({
      total: count(),
      providers: sql<string[]>`array_remove(array_agg(distinct ${cloudVmUsageEvents.provider}), null)`,
    })
    .from(cloudVmUsageEvents)
    .where(and(
      inArray(cloudVmUsageEvents.eventType, [...CREATE_FAILURE_EVENT_TYPES]),
      gte(cloudVmUsageEvents.createdAt, since),
    ));
  const row = rows[0];
  return {
    count: Number(row?.total ?? 0),
    providers: Array.isArray(row?.providers) ? row.providers : [],
  };
}

async function listStuckProvisioningVms(
  db: ReturnType<typeof cloudDb>,
  before: Date,
): Promise<Array<{ id: string }>> {
  return db
    .select({ id: cloudVms.id })
    .from(cloudVms)
    .where(and(eq(cloudVms.status, "provisioning"), lt(cloudVms.createdAt, before)))
    .limit(25);
}

async function countExpiredUnrevokedLeases(
  db: ReturnType<typeof cloudDb>,
  now: Date,
): Promise<number> {
  const rows = await db
    .select({ total: count() })
    .from(cloudVmLeases)
    .where(and(lt(cloudVmLeases.expiresAt, now), isNull(cloudVmLeases.revokedAt)));
  return Number(rows[0]?.total ?? 0);
}

function positiveIntegerEnv(value: string | undefined, fallback: number): number {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return fallback;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
