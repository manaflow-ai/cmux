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
}: {
  checkoutHref: string;
  requiresSignIn?: boolean;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
  interval?: BillingInterval;
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      requiresSignIn={requiresSignIn}
      location={location}
      interval={interval}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
