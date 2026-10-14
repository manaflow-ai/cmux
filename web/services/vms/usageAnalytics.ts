// `cloud_vm_usage_hourly`: the cost signal. Once an hour, one PostHog event
// per machine that ran during the previous whole UTC hour, with the seconds it
// ran and the shape it reserved. Multiplied by provider list rates it gives
// cost per machine, plan and team; against net revenue it gives margin.
//
// Running time comes from `cloud_vm_runtime_intervals`, which a database
// trigger opens and closes with every status change (the Go plan meters from
// it), so a lost request or event cannot skew it. A machine that ran for part
// of the hour reports only that part; paused time is not running time.
//
// Volume is one event per running machine per hour, capped at
// VM_USAGE_HOURLY_MAX_MACHINES per run. A run that hits the cap reports it and
// the overflow is not sent. The natural insert id makes a retried run of the
// same hour idempotent.
import { and, eq, gt, isNull, lt, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudVmRuntimeIntervals, cloudVms, hexclaveUsers } from "../../db/schema";
import {
  captureServerEventBatch,
  serverAnalyticsEnabled,
  type ServerEventDependencies,
  type ServerEventInput,
} from "../analytics/serverEvents";
import { isSyntheticAccountEmail } from "../analytics/syntheticAccounts";
import {
  hasVmResourceReservationMetadata,
  vmResourceReservationFromMetadata,
} from "./machineSpec";

export const VM_USAGE_HOURLY_EVENT = "cloud_vm_usage_hourly";
export const VM_USAGE_HOURLY_SCHEMA_VERSION = 1;
/** Hard cap on events per run; far above today's fleet. */
export const VM_USAGE_HOURLY_MAX_MACHINES = 5_000;

const HOUR_MS = 60 * 60 * 1000;
const MB_PER_GIB = 1024;

/** One runtime interval that overlaps the hour, joined with its machine. */
export type VmUsageIntervalRow = {
  readonly vmId: string;
  readonly userId: string;
  readonly billingTeamId: string | null;
  readonly billingPlanId: string | null;
  readonly provider: string;
  readonly providerMetadata: Record<string, unknown> | null;
  readonly primaryEmail: string | null;
  readonly startedAt: Date;
  readonly endedAt: Date | null;
};

export type VmUsageHourWindow = { readonly start: Date; readonly end: Date };

/** The previous whole UTC hour before `now`. */
export function previousUtcHour(now: Date): VmUsageHourWindow {
  const end = new Date(Math.floor(now.getTime() / HOUR_MS) * HOUR_MS);
  return { start: new Date(end.getTime() - HOUR_MS), end };
}

/**
 * Fold interval rows into one event per machine. Pure: the window, the rows
 * and the cap fully decide the result.
 */
export function vmUsageHourlyEvents(
  rows: readonly VmUsageIntervalRow[],
  window: VmUsageHourWindow,
  maxMachines: number = VM_USAGE_HOURLY_MAX_MACHINES,
): { readonly events: ServerEventInput[]; readonly machines: number; readonly truncated: number } {
  const byVm = new Map<string, { row: VmUsageIntervalRow; runningMs: number }>();
  for (const row of rows) {
    const overlapMs = Math.min(row.endedAt?.getTime() ?? window.end.getTime(), window.end.getTime()) -
      Math.max(row.startedAt.getTime(), window.start.getTime());
    if (overlapMs <= 0) continue;
    const entry = byVm.get(row.vmId);
    if (entry) entry.runningMs += overlapMs;
    else byVm.set(row.vmId, { row, runningMs: overlapMs });
  }
  const machines = [...byVm.values()];
  const events = machines.slice(0, maxMachines).map(({ row, runningMs }) => usageEvent(row, runningMs, window));
  return { events, machines: machines.length, truncated: Math.max(0, machines.length - maxMachines) };
}

function usageEvent(row: VmUsageIntervalRow, runningMs: number, window: VmUsageHourWindow): ServerEventInput {
  const reservation = vmResourceReservationFromMetadata(row.providerMetadata);
  const hourStart = window.start.toISOString();
  return {
    event: VM_USAGE_HOURLY_EVENT,
    distinctId: row.userId,
    teamId: row.billingTeamId,
    properties: {
      product: "cloud_vm",
      vm_id: row.vmId,
      plan_id: row.billingPlanId?.trim().toLowerCase().slice(0, 40) || undefined,
      provider: row.provider,
      billing_team_id: row.billingTeamId ?? undefined,
      hour_start: hourStart,
      // Overlapping intervals of one machine cannot exceed the hour.
      running_seconds: Math.min(3600, Math.round(runningMs / 1000)),
      vcpu: reservation.vcpus,
      memory_gib: reservation.memoryMb / MB_PER_GIB,
      disk_gib: reservation.diskMb / MB_PER_GIB,
      // Legacy rows without a reservation marker report the default shape.
      resources_estimated: !hasVmResourceReservationMetadata(row.providerMetadata),
      is_synthetic: isSyntheticAccountEmail(row.primaryEmail) ? true : undefined,
      schema_version: VM_USAGE_HOURLY_SCHEMA_VERSION,
    },
    insertId: `${VM_USAGE_HOURLY_EVENT}:${row.vmId}:${hourStart}`,
    // Stamped at the end of the hour it describes, so a daily rollup puts
    // the usage on the day it happened.
    timestamp: new Date(window.end.getTime() - 1),
  };
}

/** Interval rows overlapping the window. Bounded one past the cap so truncation is visible. */
async function loadUsageIntervals(window: VmUsageHourWindow): Promise<VmUsageIntervalRow[]> {
  const rows = await cloudDb()
    .select({
      vmId: cloudVms.id,
      userId: cloudVms.userId,
      billingTeamId: cloudVms.billingTeamId,
      billingPlanId: cloudVms.billingPlanId,
      provider: cloudVms.provider,
      providerMetadata: cloudVms.providerMetadata,
      primaryEmail: hexclaveUsers.primaryEmail,
      startedAt: cloudVmRuntimeIntervals.startedAt,
      endedAt: cloudVmRuntimeIntervals.endedAt,
    })
    .from(cloudVmRuntimeIntervals)
    .innerJoin(cloudVms, eq(cloudVms.id, cloudVmRuntimeIntervals.vmId))
    .leftJoin(hexclaveUsers, eq(hexclaveUsers.id, cloudVms.userId))
    .where(and(
      lt(cloudVmRuntimeIntervals.startedAt, window.end),
      or(isNull(cloudVmRuntimeIntervals.endedAt), gt(cloudVmRuntimeIntervals.endedAt, window.start)),
    ))
    // A machine has at most a few intervals in one hour; this bounds a
    // pathological flapping machine set without hiding a normal fleet.
    .limit(VM_USAGE_HOURLY_MAX_MACHINES * 4);
  return rows;
}

export type VmUsageHourlySummary = {
  readonly hourStart: string;
  /** False outside production (no force flag): nothing was read or sent. */
  readonly enabled: boolean;
  readonly machines: number;
  readonly sent: number;
  readonly failed: number;
  readonly truncated: number;
};

/** Emit the previous hour's usage. Throws only when the database read fails. */
export async function captureVmUsageHourly(
  now: Date = new Date(),
  dependencies: Partial<ServerEventDependencies> = {},
): Promise<VmUsageHourlySummary> {
  const window = previousUtcHour(now);
  const hourStart = window.start.toISOString();
  if (!serverAnalyticsEnabled(dependencies.env ?? process.env)) {
    return { hourStart, enabled: false, machines: 0, sent: 0, failed: 0, truncated: 0 };
  }
  const { events, machines, truncated } = vmUsageHourlyEvents(await loadUsageIntervals(window), window);
  const result = await captureServerEventBatch(events, dependencies);
  return { hourStart, enabled: true, machines, truncated, ...result };
}
