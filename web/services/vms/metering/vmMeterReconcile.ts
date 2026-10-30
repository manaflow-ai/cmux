// Reconcile for the VM meter. Freestyle sends no webhooks, so nothing tells us
// when a machine stops outside cmux (a crash, a provider-side pause). Three
// views are compared and only safe corrections are emitted:
//
// - Postgres open, provider definitively paused or gone: stop the ClickHouse
//   interval at the observation time (never bills time the machine did not
//   run past what we can prove; the status cron later closes Postgres too,
//   and its later stop loses to this earlier one by version).
// - ClickHouse open, Postgres closed: a stop the sync missed; replay it.
// - Postgres open, ClickHouse has no start: a start the sync missed; replay it.
//
// A transitional (`creating`) or unreadable status never stops the meter, and
// a machine running at the provider without an open interval is not billed
// here (it is our cost, reported as drift by the status cron).
import type { VMStatus } from "../drivers/types";
import { vmRuntimeEvents, vmRuntimeStopEvent, type VmMeterIntervalRow, type VmRuntimeEvent } from "./vmMeterEvents";

/** A provider status, or `unknown` when the read failed. */
export type VmMeterProviderStatus = VMStatus | "unknown";

export type VmMeterReconcileInput = {
  /** Postgres intervals with no `ended_at`. */
  readonly postgresOpen: readonly VmMeterIntervalRow[];
  /** ClickHouse intervals with a start and no stop. */
  readonly clickhouseOpen: readonly { readonly intervalId: string; readonly vmId: string }[];
  /** The Postgres rows of `clickhouseOpen` intervals that Postgres has closed. */
  readonly postgresClosedForClickhouseOpen: readonly VmMeterIntervalRow[];
  /** Provider status by cmux VM id, for the machines in `postgresOpen`. */
  readonly providerStatuses: ReadonlyMap<string, VmMeterProviderStatus>;
  readonly observedAt: Date;
};

export type VmMeterDrift = {
  /** Open in Postgres, paused or destroyed at the provider. */
  readonly providerStopped: number;
  /** Closed in Postgres, still open in ClickHouse. */
  readonly missedStops: number;
  /** Open in Postgres, absent from ClickHouse. */
  readonly missingStarts: number;
  /** Provider status unreadable; left open. */
  readonly unknownStatus: number;
};

export function reconcileVmMeter(input: VmMeterReconcileInput): {
  readonly events: VmRuntimeEvent[];
  readonly drift: VmMeterDrift;
} {
  const events: VmRuntimeEvent[] = [];
  const clickhouseOpen = new Set(input.clickhouseOpen.map((entry) => entry.intervalId));
  let providerStopped = 0;
  let missingStarts = 0;
  let unknownStatus = 0;
  for (const row of input.postgresOpen) {
    if (!clickhouseOpen.has(row.intervalId)) {
      missingStarts++;
      events.push(...vmRuntimeEvents(row, "postgres"));
    }
    const status = input.providerStatuses.get(row.vmId);
    if (status === "paused" || status === "destroyed") {
      providerStopped++;
      events.push(vmRuntimeStopEvent(row, input.observedAt, "reconcile"));
    } else if (status === "unknown") {
      unknownStatus++;
    }
  }
  let missedStops = 0;
  for (const row of input.postgresClosedForClickhouseOpen) {
    if (!row.endedAt || !clickhouseOpen.has(row.intervalId)) continue;
    missedStops++;
    events.push(vmRuntimeStopEvent(row, row.endedAt, "postgres"));
  }
  return { events, drift: { providerStopped, missedStops, missingStarts, unknownStatus } };
}
