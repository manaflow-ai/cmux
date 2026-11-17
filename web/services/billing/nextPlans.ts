// cmux NEXT Cloud plans.
//
// `next_pro` and `next_max` are plans of the cmux NEXT Cloud service, not of
// the classic app. They are stored and sent as themselves (never aliased to
// `pro` / `max`) in the same two metadata keys the classic plans use:
// `cmuxVmPlan` for an operator grant and `cmuxPlan` for a subscription.
//
// The classic app must read them as "no classic plan": every classic plan
// lookup skips a NEXT id and falls through to the next source, so a person
// who holds both a classic plan and a NEXT plan keeps the classic plan for
// classic. They are never paid classic plans (see PAID_PLAN_IDS in pro.ts)
// and never an operator restriction.

export const NEXT_PRO_PLAN_ID = "next_pro";
export const NEXT_MAX_PLAN_ID = "next_max";

/** NEXT plans in the order a team with no plan is offered them. */
export const NEXT_PLAN_IDS = [NEXT_PRO_PLAN_ID, NEXT_MAX_PLAN_ID] as const;
export type NextPlanId = (typeof NEXT_PLAN_IDS)[number];

/**
 * The metadata key that always names the NEXT subscription in force, written
 * next to `cmuxPlan`. `cmuxPlan` names the NEXT plan only while no classic
 * subscription holds it, so a person paying for both keeps both.
 */
export const NEXT_PLAN_METADATA_KEY = "cmuxNextPlan";

/** The normalized NEXT plan id, or null for any other value. */
export function nextPlanId(value: unknown): NextPlanId | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return (NEXT_PLAN_IDS as readonly string[]).includes(normalized) ? normalized as NextPlanId : null;
}

export function isNextPlanId(value: unknown): value is NextPlanId {
  return nextPlanId(value) !== null;
}

/** The higher of two NEXT plans (max beats pro), or null when neither is set. */
export function higherNextPlanId(
  left: NextPlanId | null,
  right: NextPlanId | null,
): NextPlanId | null {
  if (left === NEXT_MAX_PLAN_ID || right === NEXT_MAX_PLAN_ID) return NEXT_MAX_PLAN_ID;
  return left ?? right;
}

/**
 * The NEXT plan in force from Stack metadata: an operator grant
 * (`cmuxVmPlan`) or a subscription (`cmuxNextPlan`, else `cmuxPlan`). The
 * higher one wins, so a lower grant never hides a higher purchase.
 */
export function nextPlanIdFromMetadata(raw: unknown): NextPlanId | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const metadata = raw as Record<string, unknown>;
  const subscribed = nextPlanId(metadata[NEXT_PLAN_METADATA_KEY]) ?? nextPlanId(metadata.cmuxPlan);
  return higherNextPlanId(nextPlanId(metadata.cmuxVmPlan), subscribed);
}
