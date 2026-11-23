/**
 * The cmux Cloud free week (RFD 0052, plan id `next_taste`): seven days of one
 * on-demand Chief on the smallest machine, with 1,200 machine-minutes. No card,
 * no payment. The platform enforces machine sizes and minutes; web only grants
 * and ends it.
 *
 * Everything in this file is pure: the term, the daily cap, what is included,
 * the eligibility rules and the refusal codes. The store and the grant live in
 * services/billing/cloudTasteGrants.ts. It shares the pass's flag
 * (`isCloudIntroEnabled`) and its three `clientReadOnlyMetadata` keys.
 */
import { CLOUD_TASTE_PLAN_ID, type CloudIntroTerm } from "./cloudIntro";

export { CLOUD_TASTE_PLAN_ID };

/** `?welcome=` on Plan & billing after a granted free week. */
export const CLOUD_TASTE_WELCOME = "taste" as const;

export const CLOUD_TASTE_TERM_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;
export const CLOUD_TASTE_TERM_MS = CLOUD_TASTE_TERM_DAYS * DAY_MS;

/** Free weeks granted per UTC day. */
export const CLOUD_TASTE_DAILY_CAP = 100;

/** What the free week includes, for the pricing page. */
export const CLOUD_TASTE_INCLUDED = {
  /** On-demand Chiefs. */
  chiefs: 1,
  /** vCPUs of the smallest machine the Chief runs on. */
  chiefVcpu: 2,
  /** Machine-minutes: one vCPU awake for one minute. */
  machineMinutes: 1_200,
} as const;

/** Awake hours the machine-minutes give the Chief: 1,200 / (2 vCPU x 60) = 10. */
export const CLOUD_TASTE_AWAKE_HOURS = CLOUD_TASTE_INCLUDED.machineMinutes / (CLOUD_TASTE_INCLUDED.chiefVcpu * 60);

export type CloudTasteFacts = {
  /** The account has or had a paid plan (the pass's definition). */
  readonly hadPaidPlan: boolean;
  /** The account holds a seat on a team with an active Team plan. */
  readonly isTeamSeat: boolean;
  /** The account was granted a $1 pass. */
  readonly hadPass: boolean;
  /** The account was granted a free week before. */
  readonly hadTaste: boolean;
  /** Another member of a team the account belongs to got a free week. */
  readonly teamHadTaste: boolean;
  /** Free weeks granted since the start of the current UTC day. */
  readonly grantedToday: number;
};

export type CloudTasteRefusal =
  | "had_paid_plan"
  | "already_had_pass"
  | "already_had_taste"
  | "team_seat"
  | "team_already_had_taste"
  | "daily_cap_reached";

/** The first rule the account breaks, or null. Permanent reasons come before the daily cap. */
export function cloudTasteRefusal(facts: CloudTasteFacts): CloudTasteRefusal | null {
  if (facts.hadPaidPlan) return "had_paid_plan";
  if (facts.hadPass) return "already_had_pass";
  if (facts.hadTaste) return "already_had_taste";
  if (facts.isTeamSeat) return "team_seat";
  if (facts.teamHadTaste) return "team_already_had_taste";
  if (facts.grantedToday >= CLOUD_TASTE_DAILY_CAP) return "daily_cap_reached";
  return null;
}

/** What a pricing page says for each refusal. No vendor names, no costs. */
export const CLOUD_TASTE_BILLING_COPY = {
  taste_sold_out_today: "Today's free Chief weeks are gone. Try again tomorrow.",
  taste_unavailable: "The free Chief week is not available for this account.",
} as const;

export type CloudTasteBillingCode = keyof typeof CLOUD_TASTE_BILLING_COPY;

/** The `/pricing?billing=` code for a refusal. */
export function cloudTasteRefusalBillingCode(refusal: CloudTasteRefusal): CloudTasteBillingCode {
  return refusal === "daily_cap_reached" ? "taste_sold_out_today" : "taste_unavailable";
}

/** The free week's `/pricing?billing=` code, or null for any other value. */
export function cloudTasteBillingCode(value: string | null | undefined): CloudTasteBillingCode | null {
  return value && Object.hasOwn(CLOUD_TASTE_BILLING_COPY, value) ? value as CloudTasteBillingCode : null;
}

/** The free week runs for 7 days from the grant. */
export function cloudTasteTerm(startedAt: Date): CloudIntroTerm {
  return { startedAt, endsAt: new Date(startedAt.getTime() + CLOUD_TASTE_TERM_MS) };
}
