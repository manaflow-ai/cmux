/**
 * cmux-next Chief pricing: PROPOSAL data and calculator math.
 *
 * Nothing here is sold yet. No Stripe Product or Price reads these numbers;
 * the live plans stay in `plans.ts`. Design and sources:
 * plans/cmux-next/pricing-DESIGN.md. The user approves the numbers before
 * any Stripe object is made or the page leaves preview.
 *
 * Unit: Chief credits are US dollars (the backend ledger stores integer
 * micro-dollars, backend/apps/api/src/credits.ts). One credit balance pays
 * for model tokens and sandbox time.
 */

export const CHIEF_PRICE_VERSION = "chief-2026-10-proposal-1";

export type ChiefPlanId = "free" | "pro" | "max" | "team" | "enterprise";

export type SandboxSize = { vcpu: number; gib: number };

export type ChiefPlan = {
  id: ChiefPlanId;
  /** Monthly price in USD, per seat when `perSeat`; null = custom (Enterprise). */
  monthlyUsd: number | null;
  /** Monthly equivalent when billed yearly; null = no yearly price. */
  annualMonthlyUsd: number | null;
  perSeat: boolean;
  /** Chief credits (USD) included each month, per seat when `perSeat`. */
  includedCreditsUsd: number;
  /** True: usage stops at the included credits (no top-ups, no overage). */
  hardStop: boolean;
  /** Hosted frontier models (Claude, GPT) from credits. BYO subscriptions work on every plan. */
  frontierModels: boolean;
  /** Sandboxes Chief may run at once (per seat when `perSeat`). */
  parallelSandboxes: number;
  /** Largest sandbox Chief may start. */
  maxSandbox: SandboxSize;
};

export const CHIEF_PLANS: readonly ChiefPlan[] = [
  {
    id: "free",
    monthlyUsd: 0,
    annualMonthlyUsd: null,
    perSeat: false,
    includedCreditsUsd: 3,
    hardStop: true,
    frontierModels: false,
    parallelSandboxes: 1,
    maxSandbox: { vcpu: 2, gib: 4 },
  },
  {
    // Same Stripe prices as today's Pro (plans.ts); only the included amount is new.
    id: "pro",
    monthlyUsd: 50,
    annualMonthlyUsd: 40,
    perSeat: false,
    includedCreditsUsd: 25,
    hardStop: false,
    frontierModels: true,
    parallelSandboxes: 5,
    maxSandbox: { vcpu: 8, gib: 16 },
  },
  {
    id: "max",
    monthlyUsd: 200,
    annualMonthlyUsd: 160,
    perSeat: false,
    includedCreditsUsd: 100,
    hardStop: false,
    frontierModels: true,
    parallelSandboxes: 20,
    maxSandbox: { vcpu: 32, gib: 64 },
  },
  {
    id: "team",
    monthlyUsd: 60,
    annualMonthlyUsd: null,
    perSeat: true,
    includedCreditsUsd: 25,
    hardStop: false,
    frontierModels: true,
    parallelSandboxes: 5,
    maxSandbox: { vcpu: 8, gib: 16 },
  },
  {
    id: "enterprise",
    monthlyUsd: null,
    annualMonthlyUsd: null,
    perSeat: true,
    includedCreditsUsd: 0,
    hardStop: false,
    frontierModels: true,
    parallelSandboxes: 100,
    maxSandbox: { vcpu: 32, gib: 64 },
  },
];

export type ChiefModel = {
  id: string;
  label: string;
  kind: "open" | "frontier";
  /** USD per 1M tokens. `cacheWritePerM` is what fresh input costs (Claude writes the 1h cache). */
  inputPerM: number;
  cacheWritePerM: number;
  cachedInputPerM: number;
  outputPerM: number;
};

/**
 * Rates at provider cost (pass-through, multiplier 1.0, the 2026-10-13
 * decision in plans/cmux-next/usage-billing.md). Open models use the router
 * catalog ceiling (backend/apps/api/src/inference/catalog.ts `card`); their
 * cached rate is assumed at 20% of input where the catalog has none. Claude
 * uses the Bedrock table (model-gateway/bedrock-price.ts). GPT uses
 * developers.openai.com/api/docs/pricing (2026-10-19), cached at 10%.
 */
export const CHIEF_MODELS: readonly ChiefModel[] = [
  { id: "glm-5.3-flash", label: "GLM-5.3 Flash", kind: "open", inputPerM: 0.25, cacheWritePerM: 0.25, cachedInputPerM: 0.05, outputPerM: 0.8 },
  { id: "deepseek-v4.1-flash", label: "DeepSeek V4.1 Flash", kind: "open", inputPerM: 0.4, cacheWritePerM: 0.4, cachedInputPerM: 0.08, outputPerM: 1.5 },
  { id: "kimi-k2.7-code", label: "Kimi K2.7 Code", kind: "open", inputPerM: 1, cacheWritePerM: 1, cachedInputPerM: 0.2, outputPerM: 4 },
  { id: "glm-5.3", label: "GLM-5.3", kind: "open", inputPerM: 1.5, cacheWritePerM: 1.5, cachedInputPerM: 0.3, outputPerM: 5 },
  { id: "gpt-5.6-terra", label: "GPT-5.6 Terra", kind: "frontier", inputPerM: 2, cacheWritePerM: 2, cachedInputPerM: 0.2, outputPerM: 12 },
  { id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5", kind: "frontier", inputPerM: 2, cacheWritePerM: 4, cachedInputPerM: 0.1, outputPerM: 10 },
  { id: "claude-opus-5-5", label: "Claude Opus 5.5", kind: "frontier", inputPerM: 4, cacheWritePerM: 8, cachedInputPerM: 0.2, outputPerM: 20 },
];

/** Token mix of a Chief turn: mostly cached context, a little fresh input, little output. */
export const CHIEF_TOKEN_MIX = { fresh: 0.1, cached: 0.85, output: 0.05 } as const;

export type SandboxRates = { vcpuHourUsd: number; gibHourUsd: number; storageGibMonthUsd: number };

/** Freestyle list prices, freestyle.sh/pricing (2026-10-19). Our cost. */
export const FREESTYLE_COST_USD: SandboxRates = {
  vcpuHourUsd: 0.04032,
  gibHourUsd: 0.0129,
  storageGibMonthUsd: 0.0628,
};

/** Proposed sandbox list price: about 1.12x Freestyle, to cover snapshots, egress and idle time. */
export const SANDBOX_LIST_USD: SandboxRates = {
  vcpuHourUsd: 0.045,
  gibHourUsd: 0.0145,
  storageGibMonthUsd: 0.08,
};

/** Stripe card fee assumption for margin math: 2.9% + $0.30 per charge. */
const STRIPE_PERCENT = 0.029;
const STRIPE_FIXED_USD = 0.3;

export type ChiefUsage = {
  /** Chief turns per working day, per person. */
  turnsPerDay: number;
  /** Tokens per turn (context plus output). */
  tokensPerTurn: number;
  workdays: number;
  modelId: string;
  /** Sandbox hours per working day, per person (sum across sandboxes). */
  sandboxHoursPerDay: number;
  sandboxSize: SandboxSize;
  /** Most sandboxes running at the same moment. */
  parallelSandboxes: number;
  seats: number;
};

export const DEFAULT_CHIEF_USAGE: ChiefUsage = {
  turnsPerDay: 40,
  tokensPerTurn: 60_000,
  workdays: 22,
  modelId: "kimi-k2.7-code",
  sandboxHoursPerDay: 2,
  sandboxSize: { vcpu: 2, gib: 4 },
  parallelSandboxes: 1,
  seats: 1,
};

export type ChiefBill = {
  plan: ChiefPlanId;
  tokensMillions: number;
  openTokenUsd: number;
  frontierTokenUsd: number;
  sandboxHours: number;
  sandboxUsd: number;
  usageUsd: number;
  includedUsd: number;
  includedAppliedUsd: number;
  overageUsd: number;
  /** null for Enterprise (custom). */
  planUsd: number | null;
  totalUsd: number | null;
  /** False when the plan cannot run this usage (hard stop, model or concurrency). */
  fits: boolean;
};

export function chiefPlan(id: ChiefPlanId): ChiefPlan {
  const plan = CHIEF_PLANS.find((p) => p.id === id);
  if (!plan) throw new Error(`unknown Chief plan ${id}`);
  return plan;
}

export function chiefModel(id: string): ChiefModel {
  const model = CHIEF_MODELS.find((m) => m.id === id);
  if (!model) throw new Error(`unknown Chief model ${id}`);
  return model;
}

export function blendedUsdPerMillion(model: ChiefModel): number {
  return (
    CHIEF_TOKEN_MIX.fresh * model.cacheWritePerM +
    CHIEF_TOKEN_MIX.cached * model.cachedInputPerM +
    CHIEF_TOKEN_MIX.output * model.outputPerM
  );
}

export function sandboxHourUsd(size: SandboxSize, rates: SandboxRates = SANDBOX_LIST_USD): number {
  return size.vcpu * rates.vcpuHourUsd + size.gib * rates.gibHourUsd;
}

const fitsSize = (size: SandboxSize, max: SandboxSize) => size.vcpu <= max.vcpu && size.gib <= max.gib;

export function estimateChiefBill(planId: ChiefPlanId, usage: ChiefUsage): ChiefBill {
  const plan = chiefPlan(planId);
  const model = chiefModel(usage.modelId);
  const seats = Math.max(1, Math.floor(usage.seats));
  const people = plan.perSeat ? seats : 1;

  const tokensMillions = (usage.turnsPerDay * usage.tokensPerTurn * usage.workdays * people) / 1_000_000;
  const tokenUsd = tokensMillions * blendedUsdPerMillion(model);
  const openTokenUsd = model.kind === "open" ? tokenUsd : 0;
  const frontierTokenUsd = model.kind === "frontier" ? tokenUsd : 0;
  const sandboxHours = usage.sandboxHoursPerDay * usage.workdays * people;
  const sandboxUsd = sandboxHours * sandboxHourUsd(usage.sandboxSize);
  const usageUsd = tokenUsd + sandboxUsd;

  const includedUsd = plan.includedCreditsUsd * people;
  const includedAppliedUsd = Math.min(includedUsd, usageUsd);
  const overageUsd = usageUsd - includedAppliedUsd;
  const planUsd = plan.monthlyUsd === null ? null : plan.monthlyUsd * people;

  const fits =
    (plan.frontierModels || model.kind === "open") &&
    usage.parallelSandboxes <= plan.parallelSandboxes * people &&
    fitsSize(usage.sandboxSize, plan.maxSandbox) &&
    (!plan.hardStop || overageUsd === 0);

  return {
    plan: planId,
    tokensMillions,
    openTokenUsd,
    frontierTokenUsd,
    sandboxHours,
    sandboxUsd,
    usageUsd,
    includedUsd,
    includedAppliedUsd,
    overageUsd,
    planUsd,
    totalUsd: planUsd === null ? null : planUsd + (plan.hardStop ? 0 : overageUsd),
    fits,
  };
}

/** The cheapest self-serve plan that can run this usage; Enterprise when none can. */
export function recommendChiefPlan(usage: ChiefUsage): ChiefPlanId {
  const selfServe: ChiefPlanId[] = usage.seats > 1 ? ["team"] : ["free", "pro", "max"];
  let best: ChiefBill | null = null;
  for (const id of selfServe) {
    const bill = estimateChiefBill(id, usage);
    if (!bill.fits || bill.totalUsd === null) continue;
    if (best === null || bill.totalUsd < (best.totalUsd ?? Infinity)) best = bill;
  }
  return best?.plan ?? "enterprise";
}

/**
 * Gross margin when a subscriber spends every included credit, at our cost
 * (tokens pass-through, so one included dollar costs one dollar), after the
 * Stripe fee. The lower of the monthly and yearly prices. Null for Free and
 * Enterprise.
 */
export function worstCaseGrossMargin(plan: ChiefPlan): number | null {
  if (plan.monthlyUsd === null || plan.monthlyUsd === 0) return null;
  const prices: { perMonth: number; chargesPerMonth: number }[] = [
    { perMonth: plan.monthlyUsd, chargesPerMonth: 1 },
  ];
  if (plan.annualMonthlyUsd !== null) prices.push({ perMonth: plan.annualMonthlyUsd, chargesPerMonth: 1 / 12 });
  return Math.min(
    ...prices.map(({ perMonth, chargesPerMonth }) => {
      const fee = perMonth * STRIPE_PERCENT + STRIPE_FIXED_USD * chargesPerMonth;
      return (perMonth - fee - plan.includedCreditsUsd) / perMonth;
    }),
  );
}
