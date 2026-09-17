// Fixed JSON contracts for /api/coderouter/vm-usage*. Other surfaces
// (cmux-tui inside a VM, the dashboard) build against these shapes.
import type {
  CoderouterTeamMachineMetrics,
  CoderouterVmBreakdownRow,
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

/** Usage of one cmux-tui workspace on the machine; null = outside any workspace. */
export type VmUsageWorkspace = {
  readonly workspaceId: string | null;
  readonly totals: VmUsageTotals;
};

/** Usage of one terminal (surface) on the machine; null ids = unknown. */
export type VmUsageTerminal = {
  readonly workspaceId: string | null;
  readonly surfaceId: string | null;
  readonly totals: VmUsageTotals;
};

export type VmUsageAgent = { readonly agent: string; readonly totals: VmUsageTotals };
export type VmUsageModel = { readonly model: string; readonly totals: VmUsageTotals };

export type VmUsageResponse = {
  readonly vmId: string;
  /** The machine's display name, so a readout can name it; null when unnamed. */
  readonly displayName: string | null;
  readonly periodDays: 30;
  readonly kind: "ready" | "unavailable";
  readonly asOf: string | null;
  readonly totals: VmUsageTotals | null;
  readonly days: readonly {
    readonly day: string;
    readonly totalTokens: number;
    readonly apiEquivalentUsd: number;
  }[];
  /** Each list is ordered by total tokens descending; empty when unavailable. */
  readonly workspaces: readonly VmUsageWorkspace[];
  readonly terminals: readonly VmUsageTerminal[];
  readonly agents: readonly VmUsageAgent[];
  readonly models: readonly VmUsageModel[];
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
  displayName: string | null = null,
): VmUsageResponse {
  if (metrics.kind === "unavailable") {
    return {
      vmId,
      displayName,
      periodDays: 30,
      kind: "unavailable",
      asOf: null,
      totals: null,
      days: [],
      workspaces: [],
      terminals: [],
      agents: [],
      models: [],
    };
  }
  return {
    vmId,
    displayName,
    periodDays: 30,
    kind: "ready",
    asOf: metrics.generatedAt,
    totals: publicTotals(metrics.totals),
    days: metrics.daily.map((day) => ({
      day: day.day,
      totalTokens: day.totalTokens,
      apiEquivalentUsd: day.apiEquivalentUsd,
    })),
    workspaces: foldBreakdown(metrics.breakdown, (row) => row.workspaceId)
      .map(([workspaceId, totals]) => ({ workspaceId: workspaceId || null, totals })),
    terminals: foldBreakdown(metrics.breakdown, (row) => `${row.workspaceId}\u0000${row.surfaceId}`)
      .map(([key, totals]) => {
        const [workspaceId = "", surfaceId = ""] = key.split("\u0000");
        return { workspaceId: workspaceId || null, surfaceId: surfaceId || null, totals };
      }),
    agents: foldBreakdown(metrics.breakdown, (row) => row.agent).map(([agent, totals]) => ({ agent, totals })),
    models: foldBreakdown(metrics.breakdown, (row) => row.model).map(([model, totals]) => ({ model, totals })),
  };
}

/** Sums breakdown rows by a key; result ordered by total tokens descending, then key. */
function foldBreakdown(
  rows: readonly CoderouterVmBreakdownRow[],
  keyOf: (row: CoderouterVmBreakdownRow) => string,
): readonly (readonly [string, VmUsageTotals])[] {
  const buckets = new Map<string, { -readonly [Key in keyof VmUsageTotals]: number }>();
  for (const row of rows) {
    const key = keyOf(row);
    const bucket = buckets.get(key) ?? { ...ZERO_TOTALS };
    bucket.inputTokens += row.totals.inputTokens;
    bucket.cachedInputTokens += row.totals.cachedInputTokens;
    bucket.outputTokens += row.totals.outputTokens;
    bucket.totalTokens += row.totals.totalTokens;
    bucket.apiEquivalentUsd += row.totals.apiEquivalentUsd;
    buckets.set(key, bucket);
  }
  return [...buckets.entries()]
    .map(([key, totals]) => [key, { ...totals }] as const)
    .sort((left, right) => right[1].totalTokens - left[1].totalTokens || left[0].localeCompare(right[0]));
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
