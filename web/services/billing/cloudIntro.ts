/**
 * The cmux Cloud $1 pass (RFD 0052): $1 charged once for 30 days of cmux
 * Cloud. It is a one-time payment, never a subscription, and it never renews
 * by itself. At checkout the buyer may choose "continue on Plus after 30
 * days" (off by default); only then is the card kept for later use. The later
 * Plus charge is not built here.
 *
 * Everything in this file is pure: the price, term, caps, the flag, the
 * eligibility rules, and the `clientReadOnlyMetadata` keys the pass writes.
 * Checkout lives in services/billing/cloudIntroCheckout.ts and fulfillment in
 * services/billing/cloudIntroFulfillment.ts.
 */

/** The `plan` query value the checkout route accepts for the pass. */
export const CLOUD_INTRO_CHECKOUT_PLAN = "intro" as const;

/**
 * The plan id the pass writes to `cmuxNextPlan`. The platform ranks every real
 * plan (`cmuxPlan`, `cmuxVmPlan`) above it.
 */
export const CLOUD_INTRO_PLAN_ID = "next_intro" as const;

// Stripe Price amounts are immutable, so the lookup key carries the amount
// like the plan prices in plans.ts. The Price is one-time, not recurring.
export const CLOUD_INTRO_PRICING_USD = {
  billedAmount: 1,
  unitAmountCents: 100,
  currency: "usd",
  lookupKey: "cmux-cloud-intro-1",
} as const;

export const CLOUD_INTRO_TERM_DAYS = 30;
const DAY_MS = 24 * 60 * 60 * 1000;
export const CLOUD_INTRO_TERM_MS = CLOUD_INTRO_TERM_DAYS * DAY_MS;

/** What the pass includes, for the pricing page. */
export const CLOUD_INTRO_INCLUDED = {
  /** Awake hours for the Chief. */
  chiefAwakeHours: 100,
  /** Machine-minutes for every other machine. */
  machineMinutes: 3_000,
  /** Machines running at once. */
  concurrentMachines: 5,
} as const;

/** Machine sizes the pass allows, for the pricing page. */
export const CLOUD_INTRO_MACHINES = {
  /** The Chief, the always-on agent machine. */
  chief: { vcpu: 2, gib: 4 },
  /** The largest of the other machines. */
  otherMax: { vcpu: 4, gib: 8 },
} as const;

/** The included hours and minutes are released in this many equal weekly parts. */
export const CLOUD_INTRO_RELEASE_WEEKS = 4;

/** Days everything is kept after a pass ends and the buyer chose not to continue. */
export const CLOUD_INTRO_KEEP_DAYS = 14;

/** Passes granted per UTC day. */
export const CLOUD_INTRO_DAILY_CAP = 100;
/** Passes granted in total for the first cohort. */
export const CLOUD_INTRO_TOTAL_CAP = 1_000;
/** Checkouts an account may start for the pass. */
export const CLOUD_INTRO_MAX_CARD_ATTEMPTS = 3;

/** Stripe's receipt line for the $1 charge. */
export const CLOUD_INTRO_RECEIPT_DESCRIPTION = "cmux Cloud: $1 pass, 30 days, does not renew";
/** The card statement suffix; Stripe allows at most 22 characters with the prefix. */
export const CLOUD_INTRO_STATEMENT_SUFFIX = "CLOUD PASS";

/** `metadata.purpose` on the pass's Checkout Session and PaymentIntent. */
export const CLOUD_INTRO_CHECKOUT_PURPOSE = "cloud_intro" as const;

/** The checkout query parameter that carries the renew choice; `1` turns it on. */
export const CLOUD_INTRO_RENEW_PARAM = "renew";

/** The `clientReadOnlyMetadata` keys the pass writes. `cmuxPlan` and `cmuxVmPlan` are never touched. */
export const CLOUD_INTRO_METADATA_KEYS = {
  plan: "cmuxNextPlan",
  startedAt: "cmuxNextPlanStartedAt",
  endsAt: "cmuxNextPlanEndsAt",
} as const;

/**
 * The pass is off in Vercel production. It is on in local dev and preview
 * deployments, and in production only with CMUX_CLOUD_INTRO=1. Under test it is
 * off unless a suite sets CMUX_CLOUD_INTRO=1, so existing suites see today's
 * behaviour.
 *
 * Setting CMUX_CLOUD_INTRO=1 in production starts charging real cards. That is
 * a separate step someone takes on purpose, after the live Stripe objects
 * (scripts/stripe/provision-catalog.sh live) exist; a merge never turns it on.
 */
export function isCloudIntroEnabled(env: Record<string, string | undefined> = process.env): boolean {
  if (env.CMUX_CLOUD_INTRO === "1") return true;
  if ((env.NODE_ENV ?? "test") === "test") return false;
  return env.VERCEL_ENV !== "production";
}

/** Why an account cannot get the pass. */
export type CloudIntroRefusal =
  | "had_paid_plan"
  | "already_had_pass"
  | "team_seat"
  | "team_already_had_pass"
  | "prepaid_card"
  | "card_already_used"
  | "attempts_exhausted"
  | "total_cap_reached"
  | "daily_cap_reached";

/**
 * `checkout`: before a Checkout Session is created; the card is unknown and
 * attempts count. `payment`: after Stripe verified the payment; the card is
 * known and the started checkout no longer counts as a new attempt.
 */
export type CloudIntroStage = "checkout" | "payment";

export type CloudIntroFacts = {
  /** The account has or had a paid plan: a Stripe or App Store subscription, Founder's Edition, or an operator grant. */
  readonly hadPaidPlan: boolean;
  /** The account was granted a pass before. */
  readonly hadPass: boolean;
  /** The account is a member of a team with an active Team plan. */
  readonly isTeamSeat: boolean;
  /** A team the account belongs to already got a pass through another member. */
  readonly teamHadPass: boolean;
  /** Passes granted since the start of the current UTC day. */
  readonly grantedToday: number;
  /** Passes granted in total. */
  readonly grantedTotal: number;
  /** Pass checkouts the account started before this one. */
  readonly cardAttempts: number;
  /** The paying card's funding (`credit`, `debit`, `prepaid`, `unknown`); payment stage only. */
  readonly cardFunding?: string | null;
  /** Another account's pass was paid with the same card fingerprint; payment stage only. */
  readonly cardFingerprintUsed?: boolean;
};

/**
 * The first rule the account breaks, or null when it may have the pass. The
 * order puts permanent reasons before temporary ones, so a buyer is never
 * told to come back tomorrow for a pass they can never get.
 */
export function cloudIntroRefusal(facts: CloudIntroFacts, stage: CloudIntroStage): CloudIntroRefusal | null {
  if (facts.hadPaidPlan) return "had_paid_plan";
  if (facts.hadPass) return "already_had_pass";
  if (facts.isTeamSeat) return "team_seat";
  if (facts.teamHadPass) return "team_already_had_pass";
  if (stage === "payment") {
    if (facts.cardFunding === "prepaid") return "prepaid_card";
    if (facts.cardFingerprintUsed) return "card_already_used";
  }
  if (stage === "checkout" && facts.cardAttempts >= CLOUD_INTRO_MAX_CARD_ATTEMPTS) return "attempts_exhausted";
  if (facts.grantedTotal >= CLOUD_INTRO_TOTAL_CAP) return "total_cap_reached";
  if (facts.grantedToday >= CLOUD_INTRO_DAILY_CAP) return "daily_cap_reached";
  return null;
}

/** The `/pricing?billing=` code checkout answers with for a refusal. */
export function cloudIntroRefusalBillingCode(refusal: CloudIntroRefusal): string {
  if (refusal === "daily_cap_reached") return "intro_sold_out_today";
  if (refusal === "total_cap_reached") return "intro_sold_out";
  return "intro_unavailable";
}

/** What a pricing page says for each checkout answer. No vendor names, no costs. */
export const CLOUD_INTRO_BILLING_COPY = {
  intro_sold_out_today: "Today's $1 passes are gone. Try again tomorrow.",
  intro_sold_out: "The first $1 passes are gone.",
  intro_unavailable: "The $1 pass is not available for this account.",
} as const;

/** The start of the UTC day `now` falls in, where the daily cap resets. */
export function cloudIntroUtcDayStart(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

export type CloudIntroTerm = {
  readonly startedAt: Date;
  readonly endsAt: Date;
};

/** The pass runs for 30 days from the verified payment. */
export function cloudIntroTerm(startedAt: Date): CloudIntroTerm {
  return { startedAt, endsAt: new Date(startedAt.getTime() + CLOUD_INTRO_TERM_MS) };
}

type MetadataRecord = Record<string, unknown>;

function metadataRecord(raw: unknown): MetadataRecord {
  return raw && typeof raw === "object" && !Array.isArray(raw) ? { ...(raw as MetadataRecord) } : {};
}

/**
 * The metadata with the pass written in, or null when it already says exactly
 * that. Every other key, `cmuxPlan` and `cmuxVmPlan` included, is kept as is.
 */
export function withCloudIntroGrant(raw: unknown, term: CloudIntroTerm): MetadataRecord | null {
  const metadata = metadataRecord(raw);
  const startedAt = term.startedAt.toISOString();
  const endsAt = term.endsAt.toISOString();
  if (
    metadata[CLOUD_INTRO_METADATA_KEYS.plan] === CLOUD_INTRO_PLAN_ID &&
    metadata[CLOUD_INTRO_METADATA_KEYS.startedAt] === startedAt &&
    metadata[CLOUD_INTRO_METADATA_KEYS.endsAt] === endsAt
  ) {
    return null;
  }
  metadata[CLOUD_INTRO_METADATA_KEYS.plan] = CLOUD_INTRO_PLAN_ID;
  metadata[CLOUD_INTRO_METADATA_KEYS.startedAt] = startedAt;
  metadata[CLOUD_INTRO_METADATA_KEYS.endsAt] = endsAt;
  return metadata;
}

/** When the pass in the metadata ends, or null when the metadata names no pass. */
export function cloudIntroEndsAt(raw: unknown): Date | null {
  const metadata = metadataRecord(raw);
  if (metadata[CLOUD_INTRO_METADATA_KEYS.plan] !== CLOUD_INTRO_PLAN_ID) return null;
  const value = metadata[CLOUD_INTRO_METADATA_KEYS.endsAt];
  const endsAt = typeof value === "string" ? new Date(value) : null;
  // A pass key without a readable end is treated as already ended.
  return endsAt && Number.isFinite(endsAt.getTime()) ? endsAt : new Date(0);
}

/**
 * The metadata with an ended pass removed, or null when nothing needs to
 * change (no pass, or the pass is still running). Only the three pass keys go.
 */
export function withoutEndedCloudIntro(raw: unknown, now: Date): MetadataRecord | null {
  const endsAt = cloudIntroEndsAt(raw);
  if (!endsAt || endsAt.getTime() > now.getTime()) return null;
  const metadata = metadataRecord(raw);
  delete metadata[CLOUD_INTRO_METADATA_KEYS.plan];
  delete metadata[CLOUD_INTRO_METADATA_KEYS.startedAt];
  delete metadata[CLOUD_INTRO_METADATA_KEYS.endsAt];
  return metadata;
}

/** True when the checkout request turned on "continue on Plus after 30 days". */
export function cloudIntroRenewChosen(value: string | null | undefined): boolean {
  return value === "1" || value === "true" || value === "plus";
}
