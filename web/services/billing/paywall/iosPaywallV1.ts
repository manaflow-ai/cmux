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
  defaultBillingPeriod: "monthly",
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
    key: "focus-pro",
    name: "Focus on Pro",
    rolloutPercentage: 25,
    payload: {
      layout: "focus",
      headline: "Pro for your coding agents",
      subheadline: "Up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM, billed monthly.",
      bullets: [
        "Persistent Linux machines that keep your files and tools",
        "Check on your agents from the iOS app",
        "Email support",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
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
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
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
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  // The one billing-period challenger: control's copy with the yearly price
  // preselected. Lawrence (2026-10-15): lead with Pro Monthly and let the
  // data decide on yearly. First in the queue.
  {
    key: "pro-yearly-first",
    name: "Control copy, yearly preselected",
    rolloutPercentage: 0,
    payload: { ...IOS_PAYWALL_CONTROL_PAYLOAD, defaultBillingPeriod: "yearly" },
  },
  // Queued challengers (0%): the optimizer keeps at most 4 arms live (control
  // and 3 challengers) and promotes the next queued variant, in this order,
  // when a challenger retires. See EXPERIMENTS.md "Live arm cap".
  {
    key: "checklist-pro",
    name: "Checklist of what Pro adds",
    rolloutPercentage: 0,
    payload: {
      layout: "checklist",
      headline: "Everything Pro adds to cmux",
      subheadline: "Cloud VMs for your coding agents, billed monthly.",
      bullets: [
        "Up to 5 Cloud VMs",
        "20 vCPUs and 40 GB RAM to share",
        "A single VM can have up to 8 vCPUs and 16 GB RAM",
        "Persistent Linux machines that keep your files",
        "The iOS app and email support",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "action",
      showYearlySavings: false,
      entryPointHeadlines: {
        locked_vm_size: "Bigger VMs come with Pro",
        limit: "Need more Cloud VMs?",
      },
    },
  },
  {
    key: "plantabs-pro",
    name: "Pro and Max as tabs",
    rolloutPercentage: 0,
    payload: {
      layout: "planTabs",
      headline: "Pick the plan that fits your agents",
      subheadline: "Pro and Max both include up to 5 Cloud VMs.",
      bullets: [
        "Pro: 20 vCPUs and 40 GB RAM to share",
        "Max: 80 vCPUs and 160 GB RAM to share",
        "Max: a single VM can have up to 32 vCPUs and 64 GB RAM",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    key: "hero-pro",
    name: "Hero image, Pro",
    rolloutPercentage: 0,
    payload: {
      layout: "hero",
      headline: "Your agents, running in the cloud",
      subheadline: "Persistent Cloud VMs keep your files and tools. Check in from your iPhone or your Mac.",
      bullets: [],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
      entryPointHeadlines: {
        cloud_new_machine: "Create more Cloud VMs with Pro",
      },
    },
  },
  {
    // The app draws the spec lines the server adds as `planSpecs` (facts.ts).
    key: "speclist-specs-first",
    name: "Specs first, no bullets",
    rolloutPercentage: 0,
    payload: {
      layout: "specList",
      headline: "More cloud compute",
      subheadline: "Persistent Cloud VMs for your coding agents.",
      bullets: [],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  // Two angles per layout for the Paywall Lab and the challenger queue:
  // outcome (agents in the cloud, reached from the iPhone) and compute.
  {
    key: "cards-compute",
    name: "Cards, compute angle",
    rolloutPercentage: 0,
    payload: {
      layout: "cards",
      headline: "More cloud compute",
      subheadline: "Up to 5 Cloud VMs on Pro, sharing 20 vCPUs and 40 GB RAM.",
      bullets: [
        "Max: 80 vCPUs and 160 GB RAM to share",
        "Persistent Linux machines that keep your files",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    key: "comparison-outcome",
    name: "Comparison, outcome angle",
    rolloutPercentage: 0,
    payload: {
      layout: "comparison",
      headline: "Run coding agents in the cloud, reach them from your iPhone",
      subheadline: "Agents keep working on Cloud VMs when you close your laptop.",
      bullets: [
        "Both: up to 5 Cloud VMs",
        "Both: the iOS app and email support",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    key: "focus-outcome",
    name: "Focus on Pro, outcome angle",
    rolloutPercentage: 0,
    payload: {
      layout: "focus",
      headline: "Run coding agents in the cloud, reach them from your iPhone",
      subheadline: "Terminals keep running when you close your laptop, so your agents keep working.",
      bullets: [
        "Persistent Linux machines that keep your files and tools",
        "Check on your agents from the iOS app",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "action",
      showYearlySavings: true,
    },
  },
  {
    key: "checklist-outcome",
    name: "Checklist, outcome angle",
    rolloutPercentage: 0,
    payload: {
      layout: "checklist",
      headline: "Run coding agents in the cloud, reach them from your iPhone",
      subheadline: "What Pro adds to cmux.",
      bullets: [
        "Agents clone repos, run commands and open pull requests",
        "Terminals keep running when you close your laptop",
        "Check on your agents from the iOS app",
        "Email support",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "action",
      showYearlySavings: true,
    },
  },
  {
    key: "plantabs-outcome",
    name: "Plan tabs, outcome angle",
    rolloutPercentage: 0,
    payload: {
      layout: "planTabs",
      headline: "Run coding agents in the cloud, reach them from your iPhone",
      subheadline: "Pro and Max both include up to 5 Cloud VMs and the iOS app.",
      bullets: [
        "Agents keep working when you close your laptop",
        "Max: more compute for bigger builds",
      ],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    key: "hero-compute",
    name: "Hero, compute angle",
    rolloutPercentage: 0,
    payload: {
      layout: "hero",
      headline: "More cloud compute",
      subheadline: "Pro: up to 5 Cloud VMs sharing 20 vCPUs and 40 GB RAM.",
      bullets: [],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
      ctaStyle: "price",
      showYearlySavings: true,
    },
  },
  {
    key: "speclist-outcome",
    name: "Spec list, outcome angle",
    rolloutPercentage: 0,
    payload: {
      layout: "specList",
      headline: "Run coding agents in the cloud, reach them from your iPhone",
      subheadline: "Persistent Cloud VMs keep working when you close your laptop.",
      bullets: [],
      highlightedPlanId: "pro",
      defaultBillingPeriod: "monthly",
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
