// The experiments the optimizer runs (scripts/paywall-optimizer and the
// `paywall-optimizer` cron). Each entry pre-registers its metrics and
// decision policy; EXPERIMENTS.md explains them. Add an experiment by
// appending a definition: the optimizer, the change log and the staff
// variants route are generic over this list.
//
// Every analysis is per experiment, and every experiment is on one platform:
// iOS and web rates are never pooled.

import { IOS_PAYWALL_CONTROL_VARIANT, IOS_PAYWALL_EXPERIMENT, IOS_PAYWALL_V1_SEED } from "./iosPaywallV1";
import type { PostHogApi } from "./optimizer";
import { IOS_PAYWALL_BASE_LAYOUTS, validateIosPaywallPayload, type ValidationResult } from "./validator";

const isBaseLayout = (layout: string) => (IOS_PAYWALL_BASE_LAYOUTS as readonly string[]).includes(layout);

/** A count over people exposed to the experiment, after their first exposure. */
export type ExperimentMetric = {
  readonly key: string;
  readonly label: string;
  readonly event: string;
  /** HogQL predicate over the metric event (trusted, from this file only). */
  readonly where: string;
};

export type ExperimentPolicy = {
  /** Every live variant needs this many exposed people before traffic moves. */
  readonly minExposuresPerVariant: number;
  /** Control never gets less than this share of traffic. */
  readonly controlFloor: number;
  /** A variant may be retired only after this many exposed people. */
  readonly retireMinExposures: number;
  /** Retire a variant whose probability of being best is below this. */
  readonly retireBelowProbability: number;
  /** Halt all changes when the sample-ratio-mismatch test p-value is below this. */
  readonly srmAlpha: number;
  /**
   * At most this many arms (control included) get traffic at once; queued
   * variants (0%, never retired) are promoted in flag order as challengers retire.
   */
  readonly maxLiveArms: number;
};

export type ExperimentDefinition = {
  readonly key: string;
  /** The PostHog multivariate flag that assigns variants. */
  readonly flagKey: string;
  readonly platform: "ios" | "web";
  readonly controlVariant: string;
  /** Exposures and conversions before this date are ignored. */
  readonly startDate: string;
  /**
   * HogQL predicate over this experiment's `paywall_assigned` events
   * (exclusions: internal, synthetic, non-production). iOS: the server sends
   * them when it serves a variant. Web: the browser sends them with the arm
   * the proxy cookie assigned.
   */
  readonly assignmentWhere: string;
  /**
   * The client event that is the exposure: the person actually saw the
   * paywall or pricing page (iOS: `ios_paywall_viewed`; web: the pricing
   * view). It must carry `paywall_experiment`; the variant always comes from
   * the assignment record (iOS: server-assigned; web: proxy cookie), never
   * from the exposure event.
   */
  readonly exposureEvent: string;
  /** HogQL predicate over the exposure event (web experiments add bot filtering here). */
  readonly exposureWhere: string;
  readonly primary: ExperimentMetric;
  readonly secondary: readonly ExperimentMetric[];
  readonly guardrails: readonly ExperimentMetric[];
  readonly policy: ExperimentPolicy;
  /**
   * The challenger queue, in promotion order: variants that start at 0% and
   * go live one at a time as challengers retire (live-arm cap).
   */
  readonly queue?: readonly string[];
  /**
   * Why a queued variant cannot go live yet (for example, apps cannot draw
   * its layout), or null when it can. Checked before every promotion.
   */
  readonly promotionGate?: (variant: string, payload: unknown, api: PostHogApi) => Promise<string | null>;
  /** Validates one variant's flag payload; invalid payloads are never served. */
  readonly validatePayload: (payload: unknown, variant: string) => ValidationResult<unknown>;
};

export const DEFAULT_EXPERIMENT_POLICY: ExperimentPolicy = {
  minExposuresPerVariant: 50,
  controlFloor: 0.1,
  retireMinExposures: 300,
  retireBelowProbability: 0.02,
  srmAlpha: 0.001,
  maxLiveArms: 4,
};

/**
 * Assignment exclusions every experiment shares: internal and synthetic
 * accounts and non-production channels. `paywall_assigned` events carry
 * these properties (sent by the server on iOS, by the browser on the web);
 * web experiments add bot filtering in their exposure predicate.
 */
export const COMMON_EXPOSURE_EXCLUSIONS = [
  "coalesce(toString(properties.paywall_internal), '') NOT IN ('true', '1')",
  "coalesce(toString(properties.is_synthetic), '') NOT IN ('true', '1')",
  "properties.paywall_channel = 'production'",
].join(" AND ");

export const IOS_PAYWALL_V1: ExperimentDefinition = {
  key: IOS_PAYWALL_EXPERIMENT,
  flagKey: IOS_PAYWALL_EXPERIMENT,
  platform: "ios",
  controlVariant: IOS_PAYWALL_CONTROL_VARIANT,
  startDate: "2026-10-15",
  assignmentWhere: `properties.paywall_platform = 'ios' AND ${COMMON_EXPOSURE_EXCLUSIONS}`,
  exposureEvent: "ios_paywall_viewed",
  exposureWhere: "1 = 1",
  primary: {
    key: "paid_subscriber",
    label: "Paid entitlement granted (App Store, Production)",
    event: "subscription_entitlement_granted",
    where: "properties.source = 'apple' AND properties.environment = 'Production'",
  },
  secondary: [
    {
      key: "cta_tapped",
      label: "Tapped a paywall call to action",
      event: "ios_paywall_cta_tapped",
      where: `properties.paywall_experiment = '${IOS_PAYWALL_EXPERIMENT}'`,
    },
  ],
  guardrails: [
    { key: "refunded", label: "Refunded", event: "subscription_refunded", where: "1 = 1" },
    { key: "revoked", label: "Revoked", event: "subscription_revoked", where: "1 = 1" },
  ],
  policy: DEFAULT_EXPERIMENT_POLICY,
  // Seed order, with variants every app can draw first.
  queue: IOS_PAYWALL_V1_SEED
    .filter((variant) => variant.rolloutPercentage === 0)
    .map((variant, index) => ({ key: variant.key, rank: (isBaseLayout(variant.payload.layout) ? 0 : 1000) + index }))
    .sort((left, right) => left.rank - right.rank)
    .map((variant) => variant.key),
  promotionGate: (_variant, payload, api) => iosLayoutAdoptionGate(payload, api),
  validatePayload: (payload, variant) => validateIosPaywallPayload(payload, IOS_PAYWALL_EXPERIMENT, variant),
};

/** Share of recent assignments whose app must be able to draw a layout before an arm using it goes live. */
export const LAYOUT_ADOPTION_THRESHOLD = 0.9;
const LAYOUT_ADOPTION_MIN_ASSIGNMENTS = 20;

/**
 * A variant whose layout older apps cannot draw is promoted only when at
 * least 90% of the last 14 days' assignments came from apps that declare that
 * layout; otherwise most of its users would see `cards` and the arm would be
 * judged on the wrong screen. Base layouts are always drawable.
 */
async function iosLayoutAdoptionGate(payload: unknown, api: PostHogApi): Promise<string | null> {
  const layout = payload && typeof payload === "object" ? (payload as { layout?: unknown }).layout : undefined;
  if (typeof layout !== "string" || isBaseLayout(layout)) return null;
  if (!/^[A-Za-z]+$/.test(layout)) return "unknown layout";
  const rows = await api.query(`SELECT count() AS total,
      countIf(has(splitByChar(',', coalesce(toString(properties.paywall_app_layouts), '')), '${layout}')) AS drawable
    FROM events
    WHERE event = 'paywall_assigned' AND properties.paywall_experiment = '${IOS_PAYWALL_EXPERIMENT}'
      AND timestamp >= now() - toIntervalDay(14) AND (${COMMON_EXPOSURE_EXCLUSIONS})`);
  const total = Number(rows[0]?.[0] ?? 0);
  const drawable = Number(rows[0]?.[1] ?? 0);
  if (total < LAYOUT_ADOPTION_MIN_ASSIGNMENTS) return `too few recent assignments (${total}) to know if apps can draw ${layout}`;
  const share = drawable / total;
  return share >= LAYOUT_ADOPTION_THRESHOLD ? null : `only ${(share * 100).toFixed(0)}% of recent assignments came from apps that can draw ${layout}`;
}

/** Every experiment the optimizer manages, in run order. */
export const PAYWALL_EXPERIMENTS: readonly ExperimentDefinition[] = [IOS_PAYWALL_V1];

export function experimentDefinition(key: string): ExperimentDefinition | null {
  return PAYWALL_EXPERIMENTS.find((experiment) => experiment.key === key) ?? null;
}
