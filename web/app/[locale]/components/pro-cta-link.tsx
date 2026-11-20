"use client";

import {
  PricingCheckoutButton,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-shared";
import type { BillingInterval } from "../../../services/billing/plans";

export function ProCtaLink({
  checkoutHref,
  requiresSignIn,
  children,
  size = "default",
  location = "pricing_page",
  interval = "month",
  plan = "pro",
}: {
  checkoutHref: string;
  requiresSignIn?: boolean;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
  interval?: BillingInterval;
  plan?: "pro" | "max";
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
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
