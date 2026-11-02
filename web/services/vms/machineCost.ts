import { and, eq, inArray, isNull } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { runWithCloudDbQuerySignal } from "../../db/queryScope";
import { cloudVmRuntimeIntervals, cloudVms, vmProvider } from "../../db/schema";
import { FREESTYLE_COST_USD, sandboxHourUsd } from "../billing/chiefPricing";
import type { VmComputeResources } from "./machineSpec";

/**
 * What a running Cloud machine costs, for display: the hourly rate of its
 * size and when it last started. Clients multiply the two for "about $X so
 * far"; neither number is a bill. Cloud plans are flat today (no VM-hour
 * overage), so the rate is the provider's list price for the machine's shape,
 * the same Freestyle rates `web/services/billing/chiefPricing.ts` prices
 * sandboxes from. A 4 vCPU / 8 GB machine is about $0.26 an hour.
 *
 * The rate lives here, on the server, so a price change reaches every client
 * without a release; the app never carries its own rate table.
 */

/** Rate to four decimals of a dollar: enough for "$0.26/h", stable in JSON. */
function roundRate(usd: number): number {
  return Math.round(usd * 10_000) / 10_000;
}

/** Approximate on-demand e2-standard list price; billing remains authoritative. */
const GCP_E2_VCPU_HOURLY_USD = 0.0335;
const GCP_E2_MEMORY_GIB_HOURLY_USD = 0.0045;

/**
 * The hourly rate for a machine of this shape on this provider, or null when
 * the shape is unknown (a legacy row without a reservation marker, whose pool
 * claim is the provider maximum, not its size) or the provider has no rate.
 */
export function vmHourlyRateUsd(
  provider: string,
  shape: VmComputeResources | null | undefined,
): number | null {
  if (!shape) return null;
  if (!(shape.vcpus > 0) || !(shape.memoryMb > 0)) return null;
  if (provider === "gcp") {
    return roundRate(shape.vcpus * GCP_E2_VCPU_HOURLY_USD + (shape.memoryMb / 1024) * GCP_E2_MEMORY_GIB_HOURLY_USD);
  }
  if (provider !== "freestyle") return null;
  return roundRate(sandboxHourUsd({ vcpu: shape.vcpus, gib: shape.memoryMb / 1024 }, FREESTYLE_COST_USD));
}

/**
 * The cost fields one machine row carries. `runningSince` (epoch ms) is the
 * start of the machine's open runtime interval, null when it is not running
 * (paused machines cost no compute) or the lookup did not answer.
 */
export function vmCostFields(
  entry: {
    readonly provider: string;
    readonly status: string;
    readonly resourceReservation?: VmComputeResources | null;
  },
  runningSince: Date | null | undefined,
): { hourlyRateUsd: number | null; runningSince: number | null } {
  const live = entry.status === "running" || entry.status === "provisioning";
  return {
    hourlyRateUsd: vmHourlyRateUsd(entry.provider, entry.resourceReservation),
    runningSince: live && runningSince ? runningSince.getTime() : null,
  };
}

type RunningSinceDb = Pick<ReturnType<typeof cloudDb>, "select">;

/** A slower read is a stalled connection; the list answers without it. */
export const RUNNING_SINCE_LOOKUP_TIMEOUT_MS = 2_000;

/**
 * When each listed machine last started, keyed by provider VM id. Reads the
 * open interval of `cloud_vm_runtime_intervals`, which a database trigger
 * opens and closes with every status change (the Go plan meters from it), so
 * a pause and resume restarts the clock.
 *
 * Best effort and bounded like the creator-name read: a failure or a slow
 * read returns an empty map (no running time, no estimate) and reports to
 * `onFailure`. It is never worth failing the machine list over.
 */
export async function readVmRunningSince(
  providerVmIds: readonly string[],
  options: {
    readonly db?: RunningSinceDb;
    readonly timeoutMs?: number;
    readonly onFailure?: (error: unknown) => void;
  } = {},
): Promise<Map<string, Date>> {
  const since = new Map<string, Date>();
  const ids = [...new Set(providerVmIds.filter((id) => id.trim().length > 0))];
  if (ids.length === 0) return since;
  const signal = AbortSignal.timeout(options.timeoutMs ?? RUNNING_SINCE_LOOKUP_TIMEOUT_MS);
  let onAbort: (() => void) | undefined;
  const deadline = new Promise<never>((_, reject) => {
    onAbort = () => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    const query = runWithCloudDbQuerySignal(signal, async () =>
      (options.db ?? cloudDb())
        .select({
          providerVmId: cloudVms.providerVmId,
          startedAt: cloudVmRuntimeIntervals.startedAt,
        })
        .from(cloudVmRuntimeIntervals)
        .innerJoin(cloudVms, eq(cloudVms.id, cloudVmRuntimeIntervals.vmId))
        .where(and(
          isNull(cloudVmRuntimeIntervals.endedAt),
          // The unique (provider, provider_vm_id) index leads with provider;
          // naming every provider lets the lookup use it instead of a scan.
          inArray(cloudVms.provider, vmProvider.enumValues),
          inArray(cloudVms.providerVmId, ids),
        )),
    );
    // The losing side of the race must not surface as an unhandled rejection.
    query.catch(() => undefined);
    const rows = await Promise.race([query, deadline]);
    for (const row of rows) {
      if (row.providerVmId && row.startedAt instanceof Date) since.set(row.providerVmId, row.startedAt);
    }
  } catch (error) {
    try {
      options.onFailure?.(error);
    } catch {
      // Reporting is best effort; it must not turn the fallback into a 500.
    }
    return new Map();
  } finally {
    if (onAbort) signal.removeEventListener("abort", onAbort);
  }
  return since;
}
