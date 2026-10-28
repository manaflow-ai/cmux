// Cloud VM metering events (plans/cmux-next/cloud-metering-DESIGN.md). The
// meter is Postgres `cloud_vm_runtime_intervals`: a trigger opens an interval
// when a machine enters provisioning/running and closes it on any other
// status, in the same transaction as the status change. Paused time is never
// inside an interval. These rows are copied to ClickHouse
// `vm_runtime_events` as one start and one stop per interval, the billing
// source of truth for usage-based pricing.

/** One runtime interval joined with the machine it belongs to. */
export type VmMeterIntervalRow = {
  readonly intervalId: string;
  readonly vmId: string;
  readonly providerVmId: string | null;
  readonly userId: string;
  /** `billing_team_id`, else `owner_team_id`; empty for a personal machine. */
  readonly teamId: string;
  readonly planId: string | null;
  readonly provider: string;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly startedAt: Date;
  readonly endedAt: Date | null;
};

/** Who recorded a row: the Postgres meter, or the provider-state reconcile. */
export type VmMeterSource = "postgres" | "reconcile";

/** One `vm_runtime_events` row, exactly as inserted (JSONEachRow). */
export type VmRuntimeEvent = {
  readonly event_id: string;
  readonly event_type: "start" | "stop";
  readonly event_time: string;
  readonly interval_id: string;
  readonly interval_started_at: string;
  readonly vm_id: string;
  readonly stack_user_id: string;
  readonly team_id: string;
  readonly plan_id: string;
  readonly provider: string;
  readonly vcpus: number;
  readonly memory_mb: number;
  readonly source: VmMeterSource;
  readonly version: number;
};

export const VM_RUNTIME_EVENTS_TABLE = "vm_runtime_events";

/**
 * ReplacingMergeTree keeps the highest version per event id. For a stop the
 * version falls as the stop time grows, so the earliest proven stop wins and a
 * replay of the same stop (same time, same version) is a no-op. Starts have
 * one source and version 0.
 */
export function stopEventVersion(stoppedAt: Date): number {
  return Number.MAX_SAFE_INTEGER - stoppedAt.getTime();
}

/** The start (and, when closed, the stop) of one interval. */
export function vmRuntimeEvents(row: VmMeterIntervalRow, source: VmMeterSource): VmRuntimeEvent[] {
  const events = [intervalEvent(row, "start", row.startedAt, source)];
  if (row.endedAt) events.push(intervalEvent(row, "stop", row.endedAt, source));
  return events;
}

/** A stop of an interval at `stoppedAt`, used by the reconcile. */
export function vmRuntimeStopEvent(row: VmMeterIntervalRow, stoppedAt: Date, source: VmMeterSource): VmRuntimeEvent {
  return intervalEvent(row, "stop", stoppedAt, source);
}

function intervalEvent(
  row: VmMeterIntervalRow,
  type: "start" | "stop",
  at: Date,
  source: VmMeterSource,
): VmRuntimeEvent {
  return {
    event_id: `${row.intervalId}:${type}`,
    event_type: type,
    event_time: at.toISOString(),
    interval_id: row.intervalId,
    interval_started_at: row.startedAt.toISOString(),
    vm_id: row.vmId,
    stack_user_id: row.userId,
    team_id: row.teamId,
    plan_id: row.planId?.trim().toLowerCase().slice(0, 40) ?? "",
    provider: row.provider,
    vcpus: row.vcpus,
    memory_mb: row.memoryMb,
    source,
    version: type === "stop" ? stopEventVersion(at) : 0,
  };
}
