// Production sources for the vm-metering cron: Postgres runtime intervals and
// the provider's VM state. `cloud_vm_runtime_intervals` has no index on
// `ended_at`; at 13,098 rows (2026-10-27) the lookback read is a scan of a
// small table every five minutes. Add a partial index past ~1M rows.
import { and, eq, gte, inArray, isNull, or } from "drizzle-orm";

import { cloudDb } from "../../../db/client";
import { cloudVmRuntimeIntervals, cloudVms } from "../../../db/schema";
import { getProvider } from "../drivers";
import type { ProviderId } from "../drivers";
import { vmResourceReservationFromMetadata } from "../machineSpec";
import type { VmMeterIntervalRow } from "./vmMeterEvents";
import type { VmMeteringDependencies } from "./vmMeterJob";
import { defaultClickHouseDependencies } from "../../coderouter/clickhouse";

const PROVIDER_READ_TIMEOUT_MS = 10_000;

const columns = {
  intervalId: cloudVmRuntimeIntervals.id,
  vmId: cloudVms.id,
  providerVmId: cloudVms.providerVmId,
  userId: cloudVmRuntimeIntervals.userId,
  billingTeamId: cloudVms.billingTeamId,
  ownerTeamId: cloudVms.ownerTeamId,
  planId: cloudVms.billingPlanId,
  provider: cloudVms.provider,
  providerMetadata: cloudVms.providerMetadata,
  startedAt: cloudVmRuntimeIntervals.startedAt,
  endedAt: cloudVmRuntimeIntervals.endedAt,
};

type Selected = {
  intervalId: string; vmId: string; providerVmId: string | null; userId: string;
  billingTeamId: string | null; ownerTeamId: string; planId: string | null; provider: string;
  providerMetadata: Record<string, unknown> | null; startedAt: Date; endedAt: Date | null;
};

function toRow(row: Selected): VmMeterIntervalRow {
  const shape = vmResourceReservationFromMetadata(row.providerMetadata);
  return {
    intervalId: row.intervalId,
    vmId: row.vmId,
    providerVmId: row.providerVmId,
    userId: row.userId,
    teamId: row.billingTeamId || row.ownerTeamId,
    planId: row.planId,
    provider: row.provider,
    vcpus: shape.vcpus,
    memoryMb: shape.memoryMb,
    startedAt: row.startedAt,
    endedAt: row.endedAt,
  };
}

async function select(where: ReturnType<typeof and>): Promise<VmMeterIntervalRow[]> {
  const rows = await cloudDb().select(columns).from(cloudVmRuntimeIntervals)
    .innerJoin(cloudVms, eq(cloudVms.id, cloudVmRuntimeIntervals.vmId))
    .where(where);
  return rows.map(toRow);
}

export function postgresVmMeteringDependencies(env: Readonly<Record<string, string | undefined>> = process.env): VmMeteringDependencies {
  return {
    env,
    now: () => new Date(),
    clickhouse: defaultClickHouseDependencies,
    loadIntervals: (since) => select(or(
      gte(cloudVmRuntimeIntervals.startedAt, since),
      gte(cloudVmRuntimeIntervals.endedAt, since),
      isNull(cloudVmRuntimeIntervals.endedAt),
    )),
    loadOpenIntervals: () => select(and(isNull(cloudVmRuntimeIntervals.endedAt))),
    loadIntervalsById: (ids) => select(and(inArray(cloudVmRuntimeIntervals.id, [...ids]))),
    providerStatus: async (row) => {
      if (!row.providerVmId) return "unknown";
      const provider = getProvider(row.provider as ProviderId);
      if (!provider.getStatus) return "unknown";
      return provider.getStatus(row.providerVmId, { signal: AbortSignal.timeout(PROVIDER_READ_TIMEOUT_MS) });
    },
  };
}
