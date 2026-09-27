"use client";

import {
  PricingCheckoutButton,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-helpers";

export function ProCtaLink({
  checkoutHref,
  requiresSignIn,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHref: string;
  requiresSignIn?: boolean;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      requiresSignIn={requiresSignIn}
      location={location}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
