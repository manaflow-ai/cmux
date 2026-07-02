// PostHog feature flag registry for the web app (project 244066).
//
// Every runtime flag the site evaluates is declared here, and
// scripts/lint-feature-flags.py (CI: workflow-guard-tests) enforces the
// rules from https://posthog.com/newsletter/feature-flag-mistakes:
//   - naming: kebab-case, positive phrasing, a type suffix
//     (-release | -experiment | -permission), no negations
//   - owner: a GitHub handle accountable for removing the flag
//   - reviewBy: a date; once past, CI fails until the flag is removed or
//     the date is consciously extended (zombie-flag guard)
//   - defaultWhenUnavailable: the fallback when PostHog is unreachable or
//     slow — it must be the safe, always-working path
//   - single evaluation site: each key literal appears in exactly one
//     non-registry source file
// Retired keys are listed in scripts/retired-feature-flags.txt and must
// never be reused.

export type FeatureFlagDefinition = {
  readonly key: string;
  readonly owner: string;
  readonly description: string;
  readonly reviewBy: string;
  readonly defaultWhenUnavailable: boolean;
};

export const FEATURE_FLAGS = {
  proCheckout: {
    key: "pro-checkout-enabled-release",
    owner: "lawrencecchen",
    description:
      "Points the pricing page Pro CTA at /api/billing/checkout (Stack hosted purchase) instead of the download link. Off until prod Stripe Connect is live.",
    reviewBy: "2026-10-01",
    defaultWhenUnavailable: false,
  },
} as const satisfies Record<string, FeatureFlagDefinition>;
