/**
 * The cmux Cloud plans the public page shows: price, included hours of the
 * standard machine, and the price of an hour after. Pure: no React, no I/O.
 *
 * The numbers are the price book's, copied by name because the price book
 * lives in the private cmux-platform repository, which this package cannot
 * import. Change them only together with it:
 * - cmux-platform src/server/cloud/domain/Plan.ts: NEXT_*_INCLUDED_MACHINE_MINUTES
 *   and NEXT_STANDARD_MACHINE_VCPUS (launch plans, cmuxterm-hq RFD 0081,
 *   "Launch plans: no gate"; Leo, 2026-11-23: "dont gate. just go.").
 * - cmux-platform src/server/billing/Margin.ts: NEXT_PLAN_PRICES (month_usd)
 *   and NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD.
 *
 * A machine minute is one vCPU for one awake minute, so a plan's hours on the
 * standard machine are its minutes / (vCPUs x 60): 90,000 / 240 = 375.
 */

export const NEXT_PLAN_IDS = ["next_plus", "next_pro", "next_max"] as const;
export type NextPlanId = (typeof NEXT_PLAN_IDS)[number];

/** Plan.ts NEXT_PLUS/PRO/MAX_INCLUDED_MACHINE_MINUTES. */
export const NEXT_INCLUDED_MACHINE_MINUTES: Readonly<Record<NextPlanId, number>> = {
  next_plus: 90_000,
  next_pro: 225_000,
  next_max: 900_000,
};

/** Margin.ts NEXT_PLAN_PRICES[id].month_usd. */
export const NEXT_PLAN_MONTH_USD: Readonly<Record<NextPlanId, number>> = {
  next_plus: 20,
  next_pro: 50,
  next_max: 200,
};

/** Plan.ts NEXT_STANDARD_MACHINE_VCPUS: the machine every chat starts on, the one a plan's hours count. */
export const NEXT_STANDARD_MACHINE_VCPUS = 4;
/** The standard machine's memory in GB (Plan.ts: "4 vCPU / 16 GiB"). */
export const NEXT_STANDARD_MACHINE_MEMORY_GB = 16;

/** Margin.ts NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD: an awake hour of the standard machine past the plan's hours. */
export const NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD = 0.08;

/** The product name of each plan; never translated (the same names as the app's plan card). */
export const NEXT_PLAN_NAMES: Readonly<Record<NextPlanId, string>> = {
  next_plus: "cmux NEXT Plus",
  next_pro: "cmux NEXT Pro",
  next_max: "cmux NEXT Max",
};

/**
 * How many agents each plan keeps running at once: cmuxterm-hq RFD 0135
 * ("Onboarding", the plan table), which RFD 0078's rule follows (RFD 0076's
 * counts). Plan copy only: the platform does not enforce these counts yet.
 */
export const NEXT_PLAN_KEPT_RUNNING: Readonly<Record<NextPlanId, number>> = {
  next_plus: 3,
  next_pro: 5,
  next_max: 50,
};

export type CloudPlanFacts = {
  readonly id: NextPlanId;
  readonly name: string;
  readonly monthUsd: number;
  /** Awake hours of the standard machine included each month. */
  readonly includedHours: number;
  /** Agents kept running at once. */
  readonly keptRunning: number;
};

/** A plan's included awake hours of the standard machine. */
export function includedStandardMachineHours(id: NextPlanId): number {
  return NEXT_INCLUDED_MACHINE_MINUTES[id] / (NEXT_STANDARD_MACHINE_VCPUS * 60);
}

/** The plans in the page's order, smallest first. */
export function cloudPlanFacts(): readonly CloudPlanFacts[] {
  return NEXT_PLAN_IDS.map((id) => ({
    id,
    name: NEXT_PLAN_NAMES[id],
    monthUsd: NEXT_PLAN_MONTH_USD[id],
    includedHours: includedStandardMachineHours(id),
    keptRunning: NEXT_PLAN_KEPT_RUNNING[id],
  }));
}
