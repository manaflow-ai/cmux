/** The provider namespace of the control-path inventory and probe IDs. */
export const VM_HEALTH_PROVIDER = "freestyle" as const;

type ProbeCoverage = { readonly skippedBudget?: unknown; readonly probeErrors?: unknown };

export function allProbesConclusive(coverage: ProbeCoverage): boolean {
  return coverage.skippedBudget === 0 && coverage.probeErrors === 0;
}

export function confirmedHungThisSweep(entry: { readonly confirmedThisSweep?: unknown }, coverage: ProbeCoverage): boolean {
  // A legacy report could only carry a hung entry after a probe error or budget skip.
  if (entry.confirmedThisSweep === undefined) return allProbesConclusive(coverage);
  return entry.confirmedThisSweep === true;
}
