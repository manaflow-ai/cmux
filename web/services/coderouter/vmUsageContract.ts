// Fixed JSON contracts for /api/coderouter/vm-usage*. Other surfaces
// (cmux-tui inside a VM, the dashboard) build against these shapes.
import type {
  CoderouterTeamMachineMetrics,
  CoderouterVmMetrics,
  CoderouterVmMetricsTotals,
} from "./vmMetrics";
import type { TeamMachine } from "./teamMachines";

export type VmUsageTotals = {
  readonly inputTokens: number;
  readonly cachedInputTokens: number;
  readonly outputTokens: number;
  readonly totalTokens: number;
  readonly apiEquivalentUsd: number;
};

export type VmUsageResponse = {
  readonly vmId: string;
  readonly periodDays: 30;
  readonly kind: "ready" | "unavailable";
  readonly asOf: string | null;
  readonly totals: VmUsageTotals | null;
  readonly days: readonly {
    readonly day: string;
    readonly totalTokens: number;
    readonly apiEquivalentUsd: number;
  }[];
};

export type TeamMachineUsage = {
  readonly vmId: string;
  /** The id `GET /api/vm` lists for this machine; clients key rows by it. */
  readonly providerVmId: string | null;
  readonly displayName: string | null;
  readonly totals: VmUsageTotals;
};

export type TeamVmUsageResponse = {
  readonly teamId: string;
  readonly periodDays: 30;
  readonly kind: "ready" | "unavailable";
  readonly asOf: string | null;
  readonly machines: readonly TeamMachineUsage[];
};

export function publicTotals(
  totals: CoderouterVmMetricsTotals,
): VmUsageTotals {
  return {
    inputTokens: totals.inputTokens,
    cachedInputTokens: totals.cachedInputTokens,
    outputTokens: totals.outputTokens,
    totalTokens: totals.totalTokens,
    apiEquivalentUsd: totals.apiEquivalentUsd,
  };
}

const ZERO_TOTALS: VmUsageTotals = {
  inputTokens: 0,
  cachedInputTokens: 0,
  outputTokens: 0,
  totalTokens: 0,
  apiEquivalentUsd: 0,
};

export function vmUsageResponse(
  vmId: string,
  metrics: CoderouterVmMetrics,
): VmUsageResponse {
  if (metrics.kind === "unavailable") {
    return {
      vmId,
      periodDays: 30,
      kind: "unavailable",
      asOf: null,
      totals: null,
      days: [],
    };
  }
  return {
    vmId,
    periodDays: 30,
    kind: "ready",
    asOf: metrics.generatedAt,
    totals: publicTotals(metrics.totals),
    days: metrics.daily.map((day) => ({
      day: day.day,
      totalTokens: day.totalTokens,
      apiEquivalentUsd: day.apiEquivalentUsd,
    })),
  };
}

/**
 * Joins Endpoint rows with the team's own machines. Every live machine the
 * team owns is listed (zero totals when it spent nothing); a destroyed
 * machine appears only when it still has usage in the period; an Endpoint
 * row whose id the team does not own is dropped.
 */
export function teamMachineUsage(
  metrics: Extract<CoderouterTeamMachineMetrics, { kind: "ready" }>,
  owned: readonly TeamMachine[],
): readonly TeamMachineUsage[] {
  const usageByVm = new Map(
    metrics.machines.map((machine) => [machine.vmId, machine.totals]),
  );
  return owned
    .flatMap((machine) => {
      const usage = usageByVm.get(machine.vmId);
      if (!usage && machine.destroyed) return [];
      return [{
        vmId: machine.vmId,
        providerVmId: machine.providerVmId,
        displayName: machine.displayName,
        totals: usage ? publicTotals(usage) : ZERO_TOTALS,
        createdAt: machine.createdAt,
      }];
    })
    .sort((left, right) =>
      right.totals.totalTokens - left.totals.totalTokens ||
      right.createdAt.localeCompare(left.createdAt)
    )
    .map(({ vmId, providerVmId, displayName, totals }) => ({ vmId, providerVmId, displayName, totals }));
}

export function teamVmUsageResponse(
  teamId: string,
  metrics: CoderouterTeamMachineMetrics,
  owned: readonly TeamMachine[],
): TeamVmUsageResponse {
  if (metrics.kind === "unavailable") {
    return { teamId, periodDays: 30, kind: "unavailable", asOf: null, machines: [] };
  }
  return {
    teamId,
    periodDays: 30,
    kind: "ready",
    asOf: metrics.generatedAt,
    machines: teamMachineUsage(metrics, owned),
  };
}
