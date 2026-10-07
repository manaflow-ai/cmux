"use client";

import {
  PricingCheckoutButton,
  type PricingCheckoutHrefs,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-shared";

export function ProCtaLink({
  checkoutHref,
  checkoutHrefs,
  requiresSignIn,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHref?: string;
  checkoutHrefs?: PricingCheckoutHrefs;
  requiresSignIn?: boolean;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      hrefs={checkoutHrefs}
      requiresSignIn={requiresSignIn}
      location={location}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
