// cmux NEXT Cloud plans.
//
// `next_plus`, `next_pro` and `next_max` are plans of the cmux NEXT Cloud service, not of
// the classic app. They are stored and sent as themselves (never aliased to
// `pro` / `max`). An operator grant lives in its own key, `cmuxNextVmPlan`,
// beside the classic grant in `cmuxVmPlan`, so one account can hold both.
// Grants made before that key existed hold the NEXT id in `cmuxVmPlan`; they
// still read as the NEXT grant and move to `cmuxNextVmPlan` on the next admin
// write. A subscription is mirrored in `cmuxNextPlan` (and `cmuxPlan`).
//
// The classic app must read them as "no classic plan": every classic plan
// lookup skips a NEXT id and falls through to the next source, so a person
// who holds both a classic plan and a NEXT plan keeps the classic plan for
// classic. They are never paid classic plans (see PAID_PLAN_IDS in pro.ts)
// and never an operator restriction.

export const NEXT_PLUS_PLAN_ID = "next_plus";
export const NEXT_PRO_PLAN_ID = "next_pro";
export const NEXT_MAX_PLAN_ID = "next_max";

/**
 * NEXT plans in the order a team with no plan is offered them, which is also
 * lowest to highest: Plus, Pro, Max.
 */
export const NEXT_PLAN_IDS = [NEXT_PLUS_PLAN_ID, NEXT_PRO_PLAN_ID, NEXT_MAX_PLAN_ID] as const;
export type NextPlanId = (typeof NEXT_PLAN_IDS)[number];

/** A NEXT plan's place among them, lowest first (Plus 0, Pro 1, Max 2). */
export function nextPlanRank(plan: NextPlanId): number {
  return NEXT_PLAN_IDS.indexOf(plan);
}

/**
 * The metadata key that always names the NEXT subscription in force, written
 * next to `cmuxPlan`. `cmuxPlan` names the NEXT plan only while no classic
 * subscription holds it, so a person paying for both keeps both.
 */
export const NEXT_PLAN_METADATA_KEY = "cmuxNextPlan";

/**
 * The metadata key holding the operator's cmux NEXT grant (`next_plus`,
 * `next_pro` or `next_max`). Any other value in it is ignored: it is never a restriction
 * and never a classic plan.
 */
export const NEXT_GRANT_METADATA_KEY = "cmuxNextVmPlan";

/** The normalized NEXT plan id, or null for any other value. */
export function nextPlanId(value: unknown): NextPlanId | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return (NEXT_PLAN_IDS as readonly string[]).includes(normalized) ? normalized as NextPlanId : null;
}

export function isNextPlanId(value: unknown): value is NextPlanId {
  return nextPlanId(value) !== null;
}

/** The higher of two NEXT plans (Max beats Pro beats Plus), or null when neither is set. */
export function higherNextPlanId(
  left: NextPlanId | null,
  right: NextPlanId | null,
): NextPlanId | null {
  if (left === null || right === null) return left ?? right;
  return nextPlanRank(right) > nextPlanRank(left) ? right : left;
}

/**
 * The operator's cmux NEXT grant: `cmuxNextVmPlan`, else a legacy NEXT id in
 * `cmuxVmPlan`. Null when the account holds no NEXT grant.
 */
export function nextGrantPlanIdFromMetadata(raw: unknown): NextPlanId | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const metadata = raw as Record<string, unknown>;
  return nextPlanId(metadata[NEXT_GRANT_METADATA_KEY]) ?? nextPlanId(metadata.cmuxVmPlan);
}

/**
 * The NEXT plan in force from Stack metadata: an operator grant
 * (`cmuxNextVmPlan`, else a legacy NEXT id in `cmuxVmPlan`) or a subscription (`cmuxNextPlan`, else `cmuxPlan`). The
 * higher one wins, so a lower grant never hides a higher purchase.
 */
export function nextPlanIdFromMetadata(raw: unknown): NextPlanId | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const metadata = raw as Record<string, unknown>;
  const subscribed = nextPlanId(metadata[NEXT_PLAN_METADATA_KEY]) ?? nextPlanId(metadata.cmuxPlan);
  return higherNextPlanId(nextGrantPlanIdFromMetadata(metadata), subscribed);
}

/** Env var holding the Stripe Price id each NEXT plan is sold at. */
export const NEXT_PLAN_PRICE_ENV = {
  [NEXT_PLUS_PLAN_ID]: "STRIPE_PRICE_NEXT_PLUS_MONTHLY",
  [NEXT_PRO_PLAN_ID]: "STRIPE_PRICE_NEXT_PRO_MONTHLY",
  [NEXT_MAX_PLAN_ID]: "STRIPE_PRICE_NEXT_MAX_MONTHLY",
} as const satisfies Record<NextPlanId, string>;

type EnvSource = Readonly<Record<string, string | undefined>>;

/** The configured Price id for a NEXT plan, or null when it is not for sale. */
export function nextPlanPriceId(plan: NextPlanId, source: EnvSource = process.env): string | null {
  const value = source[NEXT_PLAN_PRICE_ENV[plan]]?.trim();
  return value ? value : null;
}

/** Whether checkout can sell each NEXT plan (its Price id is configured). */
export function nextPlanCheckoutAvailability(
  source: EnvSource = process.env,
): Record<NextPlanId, boolean> {
  return {
    [NEXT_PLUS_PLAN_ID]: nextPlanPriceId(NEXT_PLUS_PLAN_ID, source) !== null,
    [NEXT_PRO_PLAN_ID]: nextPlanPriceId(NEXT_PRO_PLAN_ID, source) !== null,
    [NEXT_MAX_PLAN_ID]: nextPlanPriceId(NEXT_MAX_PLAN_ID, source) !== null,
  };
}

type SubscriptionLike = {
  readonly items?: { readonly data?: readonly { readonly price?: { readonly id?: string | null; readonly lookup_key?: string | null } | null }[] } | null;
  readonly metadata?: Readonly<Record<string, string>> | null;
};

/**
 * The NEXT plan a subscription sells, or null when it sells something else.
 * A configured Price id is authoritative; a `cmux-next-*` lookup key, then
 * checkout metadata on a Price without a lookup key, are the fallbacks (the
 * same order the classic plans use).
 */
export function nextPlanIdForSubscription(
  subscription: SubscriptionLike,
  sessionMetadata?: Readonly<Record<string, string>> | null,
  source: EnvSource = process.env,
): NextPlanId | null {
  const prices = (subscription.items?.data ?? []).map((item) => item.price).filter((price) => price != null);
  // A Price id only one plan's variable holds names that plan. One that two variables hold (a miscopied id) names
  // none, so it can never relabel another plan's subscribers; the lookup key and the metadata below still decide.
  const byPriceId = NEXT_PLAN_IDS.filter((plan) => {
    const priceId = nextPlanPriceId(plan, source);
    return priceId !== null && prices.some((price) => price.id === priceId);
  });
  if (byPriceId.length === 1) return byPriceId[0]!;
  const lookupKey = prices.find((price) => typeof price.lookup_key === "string" && price.lookup_key.trim())?.lookup_key;
  if (lookupKey) {
    if (lookupKey.startsWith("cmux-next-max-")) return NEXT_MAX_PLAN_ID;
    if (lookupKey.startsWith("cmux-next-pro-")) return NEXT_PRO_PLAN_ID;
    if (lookupKey.startsWith("cmux-next-plus-")) return NEXT_PLUS_PLAN_ID;
    return null;
  }
  return nextPlanId(subscription.metadata?.plan ?? sessionMetadata?.plan);
}

/** What each NEXT plan includes, as sold on the dashboard. */
export type NextPlanOffer = {
  readonly id: NextPlanId;
  readonly priceUsdPerMonth: number;
  /**
   * Machine minutes included each month (resets monthly, no rollover). One
   * machine minute is one vCPU for one minute while the machine is awake.
   * This is what people are shown.
   */
  readonly includedMachineMinutes: number;
  /** The same allowance at list rates with 2 GiB per vCPU, for code that meters dollars. */
  readonly includedUsageUsd: number;
  readonly maxRunningMachines: number;
  /** Machines kept, running plus paused. */
  readonly maxKeptMachines: number;
  readonly maxSnapshots: number;
  readonly largestMachine: { readonly vcpus: number; readonly memoryGib: number };
  readonly maxDiskGib: number;
};

/**
 * The NEXT plans in the order they are offered (contract 2026-11-17; owner
 * decision 2026-11-18: NEXT Plus added, NEXT Pro to 32 running and 32 GiB).
 * Every plan includes 1,500 machine minutes per dollar of its price. The
 * numbers are the Cloud service's own limits; keep the two in step.
 */
export const NEXT_PLAN_OFFERS: readonly NextPlanOffer[] = [
  {
    id: NEXT_PLUS_PLAN_ID,
    priceUsdPerMonth: 20,
    includedMachineMinutes: 30_000,
    includedUsageUsd: 37,
    maxRunningMachines: 8,
    maxKeptMachines: 20,
    maxSnapshots: 20,
    largestMachine: { vcpus: 4, memoryGib: 16 },
    maxDiskGib: 64,
  },
  {
    id: NEXT_PRO_PLAN_ID,
    priceUsdPerMonth: 50,
    includedMachineMinutes: 75_000,
    includedUsageUsd: 92.5,
    maxRunningMachines: 32,
    maxKeptMachines: 50,
    maxSnapshots: 50,
    largestMachine: { vcpus: 8, memoryGib: 32 },
    maxDiskGib: 128,
  },
  {
    id: NEXT_MAX_PLAN_ID,
    priceUsdPerMonth: 200,
    includedMachineMinutes: 300_000,
    includedUsageUsd: 370,
    maxRunningMachines: 64,
    maxKeptMachines: 300,
    maxSnapshots: 300,
    largestMachine: { vcpus: 32, memoryGib: 64 },
    maxDiskGib: 256,
  },
];
