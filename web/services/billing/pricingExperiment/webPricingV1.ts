// The `web-pricing-v1` experiment: presentation variants of cmux.com/pricing.
//
// Prices, plans, features and checkout never vary. A variant chooses only the
// headline, which plan card is emphasized, a yearly-billing note and the
// billing period selected first. Every variant string passes the shared copy
// validator (../paywall/validator.ts) against the published facts; a variant
// that fails is never rendered (the page serves control).
//
// Assignment runs in the proxy (assignment.ts) from the PostHog multivariate
// flag of the same key. Each non-control variant is a statically rendered
// route (/pricing/<variant>), so the assigned page arrives as server HTML with
// no flash. The experiment is English-only: other locales always get control.
//
// Pre-registration: ../paywall/EXPERIMENTS.md (web-pricing-v1).

import type { ExperimentDefinition } from "../paywall/experiments";
import { copyErrors } from "../paywall/validator";

export const WEB_PRICING_EXPERIMENT = "web-pricing-v1";
export const WEB_PRICING_CONTROL_VARIANT = "control";

/** The sticky assignment cookie: the variant this browser was first given. */
export const WEB_PRICING_ASSIGNMENT_COOKIE = "cmux_wp1";
/**
 * Present only while this browser is in the running experiment. Exposure
 * events require it, so a paused experiment, a bot, or a preview of a variant
 * route never counts as an exposure.
 */
export const WEB_PRICING_LIVE_COOKIE = "cmux_wp1_live";

export type WebPricingPlanId = "pro" | "max";
export type WebPricingBillingPeriod = "year" | "month";

export type WebPricingPresentation = {
  /** Replaces the page title. `null` keeps the localized "Pricing". */
  readonly headline: string | null;
  /** A sentence under the title. `null` shows none. */
  readonly subheadline: string | null;
  /** The plan card drawn with an emphasized border and label. */
  readonly highlightedPlanId: WebPricingPlanId | null;
  /** The label on the emphasized card. Required when a plan is highlighted. */
  readonly highlightLabel: string | null;
  /** The period the Pro and Max cards select first (a `?interval=` link wins). */
  readonly defaultBillingPeriod: WebPricingBillingPeriod;
  /** A note under the Pro and Max buttons while yearly is selected. */
  readonly yearlyNote: string | null;
};

export type WebPricingVariant = {
  readonly key: string;
  readonly name: string;
  /** Why this variant exists: the hypothesis it tests. */
  readonly hypothesis: string;
  readonly seedRolloutPercentage: number;
  readonly presentation: WebPricingPresentation;
};

/** Control is today's page, unchanged. */
export const WEB_PRICING_CONTROL_PRESENTATION: WebPricingPresentation = {
  headline: null,
  subheadline: null,
  highlightedPlanId: null,
  highlightLabel: null,
  defaultBillingPeriod: "year",
  yearlyNote: null,
};

export const WEB_PRICING_V1_VARIANTS: readonly WebPricingVariant[] = [
  {
    key: WEB_PRICING_CONTROL_VARIANT,
    name: "Control: today's pricing page",
    hypothesis: "Baseline.",
    seedRolloutPercentage: 25,
    presentation: WEB_PRICING_CONTROL_PRESENTATION,
  },
  {
    key: "yearly-emphasis",
    name: "Yearly selected, with a yearly-billing note",
    hypothesis: "Stating that yearly costs less per month raises paid conversion without moving buyers to monthly.",
    seedRolloutPercentage: 25,
    presentation: {
      ...WEB_PRICING_CONTROL_PRESENTATION,
      subheadline: "Pro and Max cost less per month with yearly billing.",
      yearlyNote: "Yearly billing costs less per month.",
    },
  },
  {
    key: "highlight-pro",
    name: "Pro card emphasized as recommended",
    hypothesis: "One recommended plan reduces choice cost and raises Pro checkouts.",
    seedRolloutPercentage: 25,
    presentation: {
      ...WEB_PRICING_CONTROL_PRESENTATION,
      highlightedPlanId: "pro",
      highlightLabel: "Recommended",
    },
  },
  {
    key: "outcome-headline",
    name: "Outcome-first headline",
    hypothesis: "Leading with what Cloud VMs do (agents keep working) beats a bare title.",
    seedRolloutPercentage: 25,
    presentation: {
      ...WEB_PRICING_CONTROL_PRESENTATION,
      headline: "Agents keep working while your Mac sleeps",
      subheadline: "Run coding agents on persistent Cloud VMs. Close your laptop and check in from your iPhone.",
    },
  },
];

const VARIANT_KEY = /^[a-z0-9][a-z0-9-]{0,39}$/;

/** Copy errors for one variant; empty when it is safe to render. */
export function webPricingVariantErrors(variant: WebPricingVariant): string[] {
  const p = variant.presentation;
  const errors: string[] = [];
  if (!VARIANT_KEY.test(variant.key)) errors.push("key: must be a lowercase key");
  const optional = (field: string, value: string | null, maxLength: number) =>
    value === null ? [] : copyErrors(field, value, { maxLength, required: true });
  errors.push(
    ...optional("headline", p.headline, 60),
    ...optional("subheadline", p.subheadline, 140),
    ...optional("highlightLabel", p.highlightLabel, 24),
    ...optional("yearlyNote", p.yearlyNote, 80),
  );
  if ((p.highlightedPlanId === null) !== (p.highlightLabel === null)) {
    errors.push("highlightLabel: required exactly when a plan is highlighted");
  }
  return errors;
}

/** Variants that pass the validator, by key. Control always passes (it has no copy). */
const RENDERABLE: ReadonlyMap<string, WebPricingVariant> = new Map(
  WEB_PRICING_V1_VARIANTS
    .filter((variant) => webPricingVariantErrors(variant).length === 0)
    .map((variant) => [variant.key, variant]),
);

/** Non-control variant keys with their own static route. */
export const WEB_PRICING_VARIANT_ROUTE_KEYS: readonly string[] = [...RENDERABLE.keys()]
  .filter((key) => key !== WEB_PRICING_CONTROL_VARIANT);

export function renderableWebPricingVariant(key: string | null | undefined): WebPricingVariant | null {
  return typeof key === "string" ? RENDERABLE.get(key) ?? null : null;
}

export function webPricingPresentation(key: string | null | undefined): WebPricingPresentation {
  return renderableWebPricingVariant(key)?.presentation ?? WEB_PRICING_CONTROL_PRESENTATION;
}

/** The PostHog `POST /feature_flags/` body that creates the flag (scripts/pricing-experiment/create-flag.ts). */
export function webPricingV1FlagDefinition(): Record<string, unknown> {
  return {
    key: WEB_PRICING_EXPERIMENT,
    name: "Web pricing page experiment v1 (proxy-evaluated; see web/services/billing/paywall/EXPERIMENTS.md)",
    active: true,
    // Assignment is sticky through the cmux_wp1 cookie; the flag is evaluated
    // locally by the proxy on the PostHog distinct id, never by posthog-js.
    ensure_experience_continuity: false,
    filters: {
      // Eligibility (English page, not a bot) is decided by the proxy, so
      // every evaluated visitor is in the rollout. A property filter here
      // would make the proxy fail closed to control.
      groups: [{ properties: [], rollout_percentage: 100 }],
      multivariate: {
        variants: WEB_PRICING_V1_VARIANTS.map((variant) => ({
          key: variant.key,
          name: variant.name,
          rollout_percentage: variant.seedRolloutPercentage,
        })),
      },
    },
  };
}

/** The PostHog hosts whose exposures count; previews and local builds share the project key. */
export const WEB_PRICING_PRODUCTION_HOSTS = ["cmux.com", "www.cmux.com"] as const;

const NOT_TRUE = (property: string) => `coalesce(toString(${property}), '') NOT IN ('true', '1')`;
const LIVE_STRIPE = "coalesce(toString(properties.livemode), 'true') != 'false'";

/**
 * The optimizer registration (experiments.ts adds the shared policy). Web
 * visitors are a stratum of their own, never pooled with iOS. The unit is
 * the PostHog person: anonymous until sign-in, merged by identify, and pinned
 * to one arm by the `cmux_wp1` cookie instead of `paywall_assignments`
 * (an anonymous visitor has no account row).
 */
export const WEB_PRICING_V1_DEFINITION: Omit<ExperimentDefinition, "policy"> = {
  key: WEB_PRICING_EXPERIMENT,
  flagKey: WEB_PRICING_EXPERIMENT,
  platform: "web",
  controlVariant: WEB_PRICING_CONTROL_VARIANT,
  startDate: "2026-10-15",
  exposureWhere: [
    "properties.paywall_platform = 'web'",
    "properties.paywall_channel = 'production'",
    NOT_TRUE("properties.is_internal_user"),
    NOT_TRUE("properties.paywall_internal"),
    NOT_TRUE("properties.is_synthetic"),
    // Bots are refused cookies by the proxy and most run no JavaScript; this
    // drops the headless browsers that do.
    "NOT match(lower(coalesce(toString(properties.$raw_user_agent), '')), 'bot|crawl|spider|headless|lighthouse|playwright|puppeteer')",
  ].join(" AND "),
  primary: {
    key: "checkout_completed",
    label: "Paid checkout completed (live mode)",
    event: "cmux_billing_checkout_completed",
    where: [LIVE_STRIPE, NOT_TRUE("properties.is_internal"), NOT_TRUE("properties.is_synthetic")].join(" AND "),
  },
  secondary: [
    {
      key: "checkout_started",
      label: "Opened checkout from this experiment",
      event: "cmux_billing_checkout_started",
      where: `properties.experiment = '${WEB_PRICING_EXPERIMENT}'`,
    },
  ],
  guardrails: [
    { key: "refunded", label: "Refunded", event: "cmux_billing_charge_refunded", where: LIVE_STRIPE },
    {
      key: "downgrade_started",
      label: "Started a plan switch to a cheaper plan",
      event: "cmux_billing_plan_switch_started",
      where: "(properties.from_plan = 'max' AND properties.target_plan IN ('pro', 'go')) OR (properties.from_plan = 'pro' AND properties.target_plan = 'go')",
    },
  ],
  // Web variants are code, not flag payloads: a flag variant is valid only
  // when this repository defines it and its copy passes the validator.
  validatePayload: (_payload, variant) => {
    const definition = WEB_PRICING_V1_VARIANTS.find((item) => item.key === variant);
    if (!definition) return { ok: false, errors: [`${variant}: not defined in webPricingV1.ts; the proxy serves control`] };
    const errors = webPricingVariantErrors(definition);
    return errors.length > 0 ? { ok: false, errors } : { ok: true, value: definition.presentation };
  },
};
