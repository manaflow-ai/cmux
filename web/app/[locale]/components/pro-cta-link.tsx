"use client";

import {
  PricingCheckoutButton,
  type ProCheckoutHrefs,
} from "../../components/pricing-interval-selector";
import type { PricingActionSize } from "../../components/pricing-shared";

export function ProCtaLink({
  checkoutHrefs,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHrefs: ProCheckoutHrefs;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  return (
    <PricingCheckoutButton
      hrefs={checkoutHrefs}
      location={location}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
