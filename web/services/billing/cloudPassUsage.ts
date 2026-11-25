import { and, eq, gt, isNull, lt, ne, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudVmRuntimeIntervals, cloudVms } from "../../db/schema";
import { hasVmResourceReservationMetadata, vmResourceReservationFromMetadata } from "../vms/machineSpec";
import { runtimeSecondsWithinPeriod } from "../vms/planUsage";
import { CLOUD_PASS_USAGE_UNAVAILABLE, type CloudPassUsage, type CloudPassUsageReader } from "./cloudIntroStatements";

/**
 * Usage of a pass holder's own machines, read from the runtime meter
 * (`cloud_vm_runtime_intervals`, one row per stretch a machine was awake).
 *
 * - `machineMinutes`: awake minutes times the machine's vCPUs, over every
 *   personal machine (Team-billed machines draw from the team). Null when a
 *   machine that ran has no recorded shape, because its vCPUs are unknown.
 * - `machinesStarted`: machines with an awake stretch that began in the window.
 * - `chiefAwakeMinutes`: always null. No machine is marked as the Chief's
 *   yet, so its awake time cannot be told apart; the statement says so
 *   instead of guessing, and the machine-minutes include the Chief's machine.
 *
 * Without a database, or when the read fails, the result is `unavailable`.
 */
type IntervalRow = {
  readonly vmId: string;
  readonly startedAt: Date;
  readonly endedAt: Date | null;
  readonly metadata: Record<string, unknown> | null;
};

export type CloudPassIntervalQuery = (input: {
  readonly stackUserId: string;
  readonly from: Date;
  readonly to: Date;
}) => Promise<readonly IntervalRow[]>;

const personalMachine = or(isNull(cloudVms.billingPlanId), ne(cloudVms.billingPlanId, "team"));

export const drizzleCloudPassIntervals: CloudPassIntervalQuery = async ({ stackUserId, from, to }) =>
  await cloudDb()
    .select({
      vmId: cloudVmRuntimeIntervals.vmId,
      startedAt: cloudVmRuntimeIntervals.startedAt,
      endedAt: cloudVmRuntimeIntervals.endedAt,
      metadata: cloudVms.providerMetadata,
    })
    .from(cloudVmRuntimeIntervals)
    .innerJoin(cloudVms, eq(cloudVms.id, cloudVmRuntimeIntervals.vmId))
    .where(and(
      eq(cloudVmRuntimeIntervals.userId, stackUserId),
      lt(cloudVmRuntimeIntervals.startedAt, to),
      or(isNull(cloudVmRuntimeIntervals.endedAt), gt(cloudVmRuntimeIntervals.endedAt, from)),
      personalMachine,
    ));

/** Folds metered intervals into the usage figures; a pure step, so tests drive it directly. */
export function cloudPassUsageFromIntervals(
  intervals: readonly IntervalRow[],
  from: Date,
  to: Date,
): CloudPassUsage {
  let vcpuSeconds = 0;
  let shapeMissing = false;
  const started = new Set<string>();
  for (const interval of intervals) {
    const seconds = runtimeSecondsWithinPeriod([interval], from, to, to);
    if (interval.startedAt.getTime() >= from.getTime() && interval.startedAt.getTime() < to.getTime()) {
      started.add(interval.vmId);
    }
    if (seconds === 0) continue;
    if (!hasVmResourceReservationMetadata(interval.metadata)) {
      shapeMissing = true;
      continue;
    }
    vcpuSeconds += seconds * vmResourceReservationFromMetadata(interval.metadata).vcpus;
  }
  return {
    status: "read",
    chiefAwakeMinutes: null,
    machineMinutes: shapeMissing ? null : Math.ceil(vcpuSeconds / 60),
    machinesStarted: started.size,
  };
}

export function createCloudPassUsageReader(
  query: CloudPassIntervalQuery = drizzleCloudPassIntervals,
): CloudPassUsageReader {
  return async ({ stackUserId, from, to }) => {
    if (to.getTime() <= from.getTime()) {
      return { status: "read", chiefAwakeMinutes: null, machineMinutes: 0, machinesStarted: 0 };
    }
    try {
      return cloudPassUsageFromIntervals(await query({ stackUserId, from, to }), from, to);
    } catch (error) {
      if (!(error instanceof Error && /DATABASE_URL is required/.test(error.message))) {
        console.warn("[billing] cmux Cloud pass usage could not be read", {
          stackUserId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      return CLOUD_PASS_USAGE_UNAVAILABLE;
    }
  };
}
