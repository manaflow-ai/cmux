"use client";

import {
  PricingCheckoutButton,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-shared";

export function ProCtaLink({
  checkoutHref,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHref: string;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      location={location}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
