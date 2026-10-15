// Experiment and account-kind tags on a checkout.
//
// The checkout route reads the visitor's `web-pricing-v1` assignment from the
// proxy's cookies (never from a query parameter a link could forge), stores
// it on the Stripe Checkout Session and Subscription metadata, and the
// started, completed, expired and subscription events read it back. Internal
// (company) and synthetic (probe) accounts are tagged the same way, so every
// experiment count can exclude them. Analytics only: a tag never changes what
// is sold.

import { isAdminUser } from "../../admin/access";
import { isSyntheticAccountEmail } from "../../analytics/syntheticAccounts";
import {
  WEB_PRICING_ASSIGNMENT_COOKIE,
  WEB_PRICING_EXPERIMENT,
  WEB_PRICING_LIVE_COOKIE,
  renderableWebPricingVariant,
} from "./webPricingV1";

export type CheckoutExperiment = {
  readonly experiment: string;
  readonly variant: string;
};

export type CheckoutAccountKind = "internal" | "synthetic";

const METADATA = {
  experiment: "cmuxExperiment",
  variant: "cmuxExperimentVariant",
  accountKind: "cmuxAccountKind",
} as const;

type CookieReader = { get(name: string): { readonly value: string } | undefined };

/** The running assignment of this browser, or null outside the experiment. */
export function checkoutExperimentFromCookies(cookies: CookieReader): CheckoutExperiment | null {
  if (cookies.get(WEB_PRICING_LIVE_COOKIE)?.value !== "1") return null;
  const variant = cookies.get(WEB_PRICING_ASSIGNMENT_COOKIE)?.value;
  return renderableWebPricingVariant(variant) ? { experiment: WEB_PRICING_EXPERIMENT, variant: variant! } : null;
}

export function checkoutAccountKind(user: {
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
}): CheckoutAccountKind | null {
  if (isSyntheticAccountEmail(user.primaryEmail)) return "synthetic";
  if (!user.isAnonymous && user.primaryEmailVerified === true && isAdminUser(user)) return "internal";
  return null;
}

/** Stripe metadata (strings only; absent tags are omitted). */
export function checkoutTaggingMetadata(
  experiment: CheckoutExperiment | null,
  accountKind: CheckoutAccountKind | null,
): Record<string, string> {
  return {
    ...(experiment ? { [METADATA.experiment]: experiment.experiment, [METADATA.variant]: experiment.variant } : {}),
    ...(accountKind ? { [METADATA.accountKind]: accountKind } : {}),
  };
}

/**
 * PostHog properties from stored metadata. Keys appear only when tagged, so
 * an untagged checkout's event payload is unchanged.
 */
export function checkoutTaggingProperties(
  metadata: Record<string, string | null | undefined> | null | undefined,
): Record<string, string | boolean> {
  const experiment = metadata?.[METADATA.experiment];
  const variant = metadata?.[METADATA.variant];
  const accountKind = metadata?.[METADATA.accountKind];
  return {
    ...(experiment && variant ? { experiment, variant, [`$feature/${experiment}`]: variant } : {}),
    ...(accountKind === "internal" ? { is_internal: true } : {}),
    ...(accountKind === "synthetic" ? { is_synthetic: true } : {}),
  };
}
