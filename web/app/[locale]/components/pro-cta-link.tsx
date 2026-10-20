"use client";

import {
  PricingCheckoutButton,
  type PricingCheckoutHrefs,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-shared";
import type { BillingInterval } from "../../../services/billing/plans";

export function ProCtaLink({
  checkoutHref,
  checkoutHrefs,
  requiresSignIn,
  children,
  size = "default",
  location = "pricing_page",
  interval = "month",
  plan = "pro",
}: {
  checkoutHref?: string;
  checkoutHrefs?: PricingCheckoutHrefs;
  requiresSignIn?: boolean;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
  interval?: BillingInterval;
  plan?: "pro" | "max" | "team";
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      hrefs={checkoutHrefs}
      requiresSignIn={requiresSignIn}
      location={location}
      interval={interval}
      plan={plan}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
