/**
 * What the cmux NEXT pricing page sells: cmux Pro ($50/month) and cmux Max
 * ($200/month), decoupled from cmux classic's plans (plans.ts NEXT_*).
 *
 * The included amounts and machine sizes are the ones the backend already
 * enforces for the plans of the same name: included usage from the usage
 * billing catalog (backend/apps/api/src/billing-catalog.ts USAGE_PRICE_SETS,
 * Pro 20 and Max 100 USD in v1 and v2) and the largest machine from
 * web/services/vms/entitlements.ts (PLAN_MAX_MEMORY_MB 16 GB for Pro,
 * MAX_PLAN_MAX_MEMORY_MB 64 GB for Max, one vCPU per 2 GB). The Chief
 * proposal in chiefPricing.ts says Pro includes $25; the page follows the
 * backend until that proposal is approved and shipped there.
 */
import {
  NEXT_MAX_PLAN_ID,
  NEXT_PLAN_PRICING_USD,
  NEXT_PRO_PLAN_ID,
  type NextPlanId,
} from "./plans";

export type NextPlan = {
  id: NextPlanId;
  monthlyUsd: number;
  lookupKey: string;
  /** Usage (models and Cloud machine time) included each month, in USD. */
  includedUsageUsd: number;
  /** Largest Cloud machine the plan may start. */
  maxMachine: { vcpu: number; gib: number };
};

export const NEXT_PLANS: readonly NextPlan[] = [
  {
    id: NEXT_PRO_PLAN_ID,
    monthlyUsd: NEXT_PLAN_PRICING_USD[NEXT_PRO_PLAN_ID].month.billedAmount,
    lookupKey: NEXT_PLAN_PRICING_USD[NEXT_PRO_PLAN_ID].month.lookupKey,
    includedUsageUsd: 20,
    maxMachine: { vcpu: 8, gib: 16 },
  },
  {
    id: NEXT_MAX_PLAN_ID,
    monthlyUsd: NEXT_PLAN_PRICING_USD[NEXT_MAX_PLAN_ID].month.billedAmount,
    lookupKey: NEXT_PLAN_PRICING_USD[NEXT_MAX_PLAN_ID].month.lookupKey,
    includedUsageUsd: 100,
    maxMachine: { vcpu: 32, gib: 64 },
  },
];

/** The address the site already uses for sales and support (site footer, live /pricing, enterprise). */
export const NEXT_PLAN_CONTACT_EMAIL = "founders@cmux.com";

/**
 * Online checkout for cmux NEXT plans. Off: no checkout route, webhook path or
 * entitlement for a NEXT plan exists yet, and the classic checkout would grant
 * the classic plan. Until the decoupled checkout lands, every plan button
 * leads to the contact email.
 */
export const NEXT_PLAN_CHECKOUT_ENABLED = false;

function mailto(subject: string): string {
  return `mailto:${NEXT_PLAN_CONTACT_EMAIL}?subject=${encodeURIComponent(subject)}`;
}

const PLAN_EMAIL_SUBJECT: Readonly<Record<NextPlanId, string>> = {
  [NEXT_PRO_PLAN_ID]: "cmux NEXT: cmux Pro",
  [NEXT_MAX_PLAN_ID]: "cmux NEXT: cmux Max",
};

/**
 * Where a plan's button leads. Never the classic checkout or `/pricing`:
 * with checkout off it is the contact email, and turning checkout on without
 * the decoupled route fails loudly instead of falling back to classic.
 */
export function nextPlanActionHref(planId: NextPlanId, checkoutEnabled: boolean = NEXT_PLAN_CHECKOUT_ENABLED): string {
  if (checkoutEnabled) {
    throw new Error("cmux NEXT checkout is not built yet; keep NEXT_PLAN_CHECKOUT_ENABLED off");
  }
  return mailto(PLAN_EMAIL_SUBJECT[planId]);
}

/** Where a classic cmux Pro subscriber asks to move their plan to cmux NEXT. */
export const NEXT_PLAN_TRANSFER_HREF = mailto("Transfer my cmux Pro plan to cmux NEXT");
