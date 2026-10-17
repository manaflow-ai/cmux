// The account-token `planFacts`: each plan's Cloud VM limits as numbers for
// the app's plan rows, generated from facts.ts (and Go's live VM-hour limit),
// never written by hand.

import { GO_INCLUDED_VM_HOURS } from "../../vms/goUsage";
import { PLAN_LIMITS, PRODUCT_FACTS, type FactPlan } from "./facts";

export type PlanFact = {
  readonly machines: number;
  readonly vcpus: number;
  readonly memoryGb: number;
  readonly largestVcpus: number;
  readonly largestMemoryGb: number;
  /** A monthly VM-hour cap, or null when the plan has none. */
  readonly vmHoursPerMonth: number | null;
};

export type PlanFacts = Partial<Record<FactPlan, PlanFact>>;

/** The facts for the plans this account is offered (Go only when it is). */
export function planFacts(offered: readonly string[]): PlanFacts {
  const facts: PlanFacts = {};
  for (const plan of ["go", "pro", "max"] as const) {
    if (!offered.includes(plan)) continue;
    facts[plan] = { ...PLAN_LIMITS[plan], vmHoursPerMonth: plan === "go" ? GO_INCLUDED_VM_HOURS : null };
  }
  return facts;
}

/**
 * PLAN_LIMITS values that no published fact states for that plan: must be
 * empty (checked by the paywall route test), so the numbers the app shows
 * are the numbers the copy validator allows.
 */
export function unpublishedPlanLimits(): string[] {
  const missing: string[] = [];
  for (const [plan, limits] of Object.entries(PLAN_LIMITS) as [FactPlan, (typeof PLAN_LIMITS)[FactPlan]][]) {
    const stated = new Set(PRODUCT_FACTS.filter((fact) => fact.plans.includes(plan)).flatMap((fact) => fact.quantities.map(([value, unit]) => `${value} ${unit}`)));
    const pairs: [string, string][] = [
      ["machines", `${limits.machines} vm`], ["vcpus", `${limits.vcpus} vcpu`], ["memoryGb", `${limits.memoryGb} gb`],
      ["largestVcpus", `${limits.largestVcpus} vcpu`], ["largestMemoryGb", `${limits.largestMemoryGb} gb`],
    ];
    for (const [field, quantity] of pairs) if (!stated.has(quantity)) missing.push(`${plan}.${field} (${quantity})`);
  }
  return missing;
}
