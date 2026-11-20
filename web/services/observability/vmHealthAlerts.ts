import type { VmHealthReport } from "../vms/health/types";
import { sendAlert, type AlertInput, type AlertResult } from "./alerts";
import { durableVmAlertStateStore, type VmAlertStateStore } from "./vmAlerts";
import { eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVmAlertStates } from "../../db/schema";

export const VM_HEALTH_ALERT_KEY = "vm-health-intervention";
const SAMPLE_LIMIT = 10;
/** A cleared alert can page again only this long after its last page. */
export const VM_HEALTH_ALERT_MIN_INTERVAL_MS = 60 * 60 * 1000;

/**
 * The operator alert for a health sweep, or null when nothing needs a person.
 * Hung VMs are critical (users cannot reach them); stuck transitions alone are
 * a warning. Drift and TLS budget stay on the page: the reconcile cron and the
 * existing TLS rule-capacity alert own those.
 */
export function vmHealthAlert(report: VmHealthReport, pageUrl: string | null): AlertInput | null {
  const hung = report.hung;
  const stuck = report.stuck;
  if (hung.length === 0 && stuck.length === 0) return null;
  const lines: string[] = [];
  if (hung.length > 0) {
    lines.push(`${hung.length} running VM(s) do not answer their control path (${countWorkloads(hung)}).`);
    lines.push(`Hung: ${hung.slice(0, SAMPLE_LIMIT).map((vm) => `${vm.vmId} since ${vm.firstSeenHungAt}`).join(", ")}${hung.length > SAMPLE_LIMIT ? ", ..." : ""}.`);
  }
  if (stuck.length > 0) {
    lines.push(`${stuck.length} VM(s) stuck in a transition: ${stuck.slice(0, SAMPLE_LIMIT).map((vm) => `${vm.vmId} ${vm.state} ${vm.minutes}m`).join(", ")}${stuck.length > SAMPLE_LIMIT ? ", ..." : ""}.`);
  }
  if (pageUrl) lines.push(`Details: ${pageUrl}`);
  return {
    key: VM_HEALTH_ALERT_KEY,
    title: hung.length > 0 ? "Cloud VMs hung" : "Cloud VMs stuck in a transition",
    body: lines.join(" "),
    severity: hung.length > 0 ? "critical" : "warning",
  };
}

function countWorkloads(vms: readonly { readonly workload: string }[]): string {
  const counts = new Map<string, number>();
  for (const vm of vms) counts.set(vm.workload, (counts.get(vm.workload) ?? 0) + 1);
  return [...counts].map(([workload, count]) => `${count} ${workload}`).join(", ");
}

export type VmHealthAlertOutcome = "none" | "sent" | "suppressed" | "unconfigured" | "failed";

/**
 * Send the sweep's alert through the shared Slack path, deduplicated by the
 * same durable state the other VM alerts use: one page when it starts, a
 * reminder every 24 hours, and an immediate re-page only on escalation to
 * critical. Only a clean sweep that saw the whole fleet clears the state, and
 * only when the last page is at least an hour old, so a VM flapping between
 * hung and healthy pages at most once an hour instead of on every run.
 */
export async function deliverVmHealthAlert(
  report: VmHealthReport,
  options: {
    readonly now?: Date;
    readonly pageUrl?: string | null;
    readonly store?: VmAlertStateStore;
    readonly send?: (input: AlertInput) => Promise<AlertResult>;
    readonly lastSentAt?: (key: string) => Promise<Date | null>;
  } = {},
): Promise<VmHealthAlertOutcome> {
  const now = options.now ?? new Date();
  const store = options.store ?? durableVmAlertStateStore(cloudDb());
  const alert = vmHealthAlert(report, options.pageUrl ?? null);
  try {
    if (!alert) {
      // A sweep that could not see the fleet is not evidence the incident is
      // over: keep the state so recovery from a blind sweep does not re-page.
      if (!sweepSawFleet(report)) return "none";
      const lastSentAt = await (options.lastSentAt ?? readLastSentAt)(VM_HEALTH_ALERT_KEY);
      if (!lastSentAt || now.getTime() - lastSentAt.getTime() >= VM_HEALTH_ALERT_MIN_INTERVAL_MS) {
        await store.clear(VM_HEALTH_ALERT_KEY, now);
      }
      return "none";
    }
    const leaseId = await store.claim(alert, now);
    if (!leaseId) return "suppressed";
    const result = await (options.send ?? ((input) => sendAlert(input)))(alert);
    if (result.sent) await store.acknowledge(VM_HEALTH_ALERT_KEY, leaseId, now);
    else await store.release?.(VM_HEALTH_ALERT_KEY, leaseId, now);
    if (result.configured === false) return "unconfigured";
    return result.sent ? "sent" : "failed";
  } catch (error) {
    console.error("vm.health.alert_failed", {
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
    return "failed";
  }
}

/** True when the sweep listed every VM, probed every running one it could, and hit no stage error. */
export function sweepSawFleet(report: VmHealthReport): boolean {
  return report.errors.length === 0 && report.coverage.inventoryComplete && report.coverage.skippedBudget === 0;
}

async function readLastSentAt(key: string): Promise<Date | null> {
  const [row] = await cloudDb()
    .select({ lastSentAt: cloudVmAlertStates.lastSentAt })
    .from(cloudVmAlertStates)
    .where(eq(cloudVmAlertStates.alertKey, key))
    .limit(1);
  return row?.lastSentAt ?? null;
}
