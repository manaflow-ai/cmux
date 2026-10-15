// The `ios-paywall-v1` experiment: the seeded variants of its PostHog
// multivariate flag. The flag is created from this file after merge
// (scripts/paywall-optimizer/create-flag.ts); after that the flag payloads in
// PostHog are the live copy, and every payload is validated before it is
// served. Control is the app's built-in copy, so a user outside the
// experiment and a user in its control arm see the same screen.

import type { IosPaywallConfig } from "./validator";

export const IOS_PAYWALL_EXPERIMENT = "ios-paywall-v1";
export const IOS_PAYWALL_CONTROL_VARIANT = "control";

type SeedPayload = Omit<IosPaywallConfig, "experiment" | "variant">;

export type SeedVariant = {
  readonly key: string;
  readonly name: string;
  readonly rolloutPercentage: number;
  readonly payload: SeedPayload;
};

/** The control copy; identical to the iOS app's built-in paywall. */
export const IOS_PAYWALL_CONTROL_PAYLOAD: SeedPayload = {
  layout: "cards",
  headline: "Upgrade to cmux Cloud",
  subheadline: "Run coding agents on fast cloud machines and reach them from your iPhone and your Mac.",
  bullets: [],
  highlightedPlanId: "pro",
  defaultBillingPeriod: "yearly",
  ctaStyle: "price",
  showYearlySavings: true,
};

export const IOS_PAYWALL_V1_SEED: readonly SeedVariant[] = [
  {
    key: IOS_PAYWALL_CONTROL_VARIANT,
    name: "Control: current app copy, cards",
    rolloutPercentage: 25,
    payload: IOS_PAYWALL_CONTROL_PAYLOAD,
  },
  {
    key: "focus-pro-yearly",
    name: "Focus on Pro, yearly first",
    rolloutPercentage: 25,
    payload: {
      layout: "focus",
      headline: "Pro for your coding agents",
      subheadline: "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM. Yearly billing costs less per month.",
      bullets: [
        "Persistent Linux machines that keep your files and tools",
        "Check on your agents from the iOS app",
        "Email support",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "yearly",
      ctaStyle: "action",
      showYearlySavings: true,
    },
  },
  {
    key: "comparison",
    name: "Pro and Max side by side",
    rolloutPercentage: 25,
    payload: {
      layout: "comparison",
      headline: "Compare Pro and Max",
      subheadline: "Both include up to 5 Cloud VMs. Max shares 80 vCPUs and 160 GB RAM for bigger builds.",
      bullets: [
        "Pro: 20 vCPUs and 40 GB RAM to share",
        "Max: a single VM can have up to 32 vCPUs and 64 GB RAM",
        "Both: the iOS app, email support and unlimited workspaces",
      ],
      highlightedPlanId: null,
      defaultBillingPeriod: "yearly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    // Starts at 0%: set it live only after the trial product, the DeviceCheck
    // key and the In-App Purchase key exist (EXPERIMENTS.md). Until then the
    // server never serves it.
    key: "pro-trial-7d",
    name: "Pro with a 7-day free trial (verified devices only)",
    rolloutPercentage: 0,
    payload: {
      layout: "focus",
      headline: "Try Pro free for 7 days",
      subheadline: "During the trial: 1 Cloud VM with 2 vCPUs and 4 GB RAM, and 20 VM-hours. Full Pro starts with the first payment.",
      bullets: [
        "Cancel before the trial ends and you pay nothing",
        "Then up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM",
        "Check on your agents from the iOS app",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "action",
      showYearlySavings: false,
    },
  },
  {
    key: "outcome-copy",
    name: "Outcome: agents keep working while the Mac sleeps",
    rolloutPercentage: 25,
    payload: {
      layout: "cards",
      headline: "Agents keep working while your Mac sleeps",
      subheadline: "Run coding agents on persistent Cloud VMs. Close your laptop and check in from your iPhone.",
      bullets: [
        "Terminals keep running when you close your laptop",
        "Agents clone repos, run commands and open pull requests",
        "Up to 5 Cloud VMs on Pro",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "yearly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
];

/** The control config, served to everyone outside the experiment. */
export const IOS_PAYWALL_CONTROL: IosPaywallConfig = {
  experiment: IOS_PAYWALL_EXPERIMENT,
  variant: IOS_PAYWALL_CONTROL_VARIANT,
  ...IOS_PAYWALL_CONTROL_PAYLOAD,
};

/** The PostHog `POST /feature_flags/` body that creates the flag. */
export function iosPaywallV1FlagDefinition(): Record<string, unknown> {
  return {
    key: IOS_PAYWALL_EXPERIMENT,
    name: "iOS paywall experiment v1 (server-evaluated; see web/services/billing/paywall/EXPERIMENTS.md)",
    active: true,
    ensure_experience_continuity: false,
    filters: {
      // Eligibility (App Store bundle, free plan, purchasable, not internal or
      // synthetic) is decided by the server before it asks for the flag, so
      // every evaluated person is in the rollout.
      groups: [{ properties: [], rollout_percentage: 100 }],
      multivariate: {
        variants: IOS_PAYWALL_V1_SEED.map((variant) => ({
          key: variant.key,
          name: variant.name,
          rollout_percentage: variant.rolloutPercentage,
        })),
      },
      payloads: Object.fromEntries(IOS_PAYWALL_V1_SEED.map((variant) => [variant.key, JSON.stringify(variant.payload)])),
    },
  };
}
