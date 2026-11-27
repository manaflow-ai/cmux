/** The provider namespace of the control-path inventory and probe IDs. */
export const VM_HEALTH_PROVIDER = "freestyle" as const;

type ProbeCoverage = { readonly skippedBudget?: unknown; readonly probeErrors?: unknown };

export function allProbesConclusive(coverage: ProbeCoverage): boolean {
  return coverage.skippedBudget === 0 && coverage.probeErrors === 0;
}

/** Legacy entries cannot distinguish a guest request timeout from a provider-state lookup timeout. */
export function confirmedHungThisSweep(entry: { readonly confirmedThisSweep?: unknown }): boolean {
  return entry.confirmedThisSweep === true;
}
