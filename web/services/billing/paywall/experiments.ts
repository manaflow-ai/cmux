// The experiments the optimizer runs (scripts/paywall-optimizer and the
// `paywall-optimizer` cron). Each entry pre-registers its metrics and
// decision policy; EXPERIMENTS.md explains them. Add an experiment by
// appending a definition: the optimizer, the change log and the staff
// variants route are generic over this list.
//
// Every analysis is per experiment, and every experiment is on one platform:
// iOS and web rates are never pooled.

import { IOS_PAYWALL_CONTROL_VARIANT, IOS_PAYWALL_EXPERIMENT } from "./iosPaywallV1";
import { validateIosPaywallPayload, type ValidationResult } from "./validator";
import { WEB_PRICING_V1_DEFINITION } from "../pricingExperiment/webPricingV1";

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
};

export type ExperimentDefinition = {
  readonly key: string;
  /** The PostHog multivariate flag that assigns variants. */
  readonly flagKey: string;
  readonly platform: "ios" | "web";
  readonly controlVariant: string;
  /** Exposures and conversions before this date are ignored. */
  readonly startDate: string;
  /** HogQL predicate over `$feature_flag_called` events, beyond the flag key. */
  readonly exposureWhere: string;
  readonly primary: ExperimentMetric;
  readonly secondary: readonly ExperimentMetric[];
  readonly guardrails: readonly ExperimentMetric[];
  readonly policy: ExperimentPolicy;
  /** Validates one variant's flag payload; invalid payloads are never served. */
  readonly validatePayload: (payload: unknown, variant: string) => ValidationResult<unknown>;
};

export const DEFAULT_EXPERIMENT_POLICY: ExperimentPolicy = {
  minExposuresPerVariant: 50,
  controlFloor: 0.1,
  retireMinExposures: 300,
  retireBelowProbability: 0.02,
  srmAlpha: 0.001,
};

/**
 * Exposure exclusions every experiment shares: internal and synthetic
 * accounts and non-production channels. Server-recorded exposures carry
 * these properties; web experiments add bot filtering in their own predicate.
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
  exposureWhere: `properties.paywall_platform = 'ios' AND ${COMMON_EXPOSURE_EXCLUSIONS}`,
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
  validatePayload: (payload, variant) => validateIosPaywallPayload(payload, IOS_PAYWALL_EXPERIMENT, variant),
};

/** cmux.com/pricing (services/billing/pricingExperiment/webPricingV1.ts). */
export const WEB_PRICING_V1: ExperimentDefinition = { ...WEB_PRICING_V1_DEFINITION, policy: DEFAULT_EXPERIMENT_POLICY };

/** Every experiment the optimizer manages, in run order. */
export const PAYWALL_EXPERIMENTS: readonly ExperimentDefinition[] = [IOS_PAYWALL_V1, WEB_PRICING_V1];

export function experimentDefinition(key: string): ExperimentDefinition | null {
  return PAYWALL_EXPERIMENTS.find((experiment) => experiment.key === key) ?? null;
}
