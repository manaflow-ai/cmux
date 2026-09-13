"use client";

import {
  PricingCheckoutButton,
} from "../../components/pricing-checkout";
import type { PricingActionSize } from "../../components/pricing-shared";

export function ProCtaLink({
  checkoutHref,
  signInHref,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHref: string;
  signInHref?: string;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  return (
    <PricingCheckoutButton
      href={checkoutHref}
      signInHref={signInHref}
      location={location}
      size={size}
    >
      {children}
    </PricingCheckoutButton>
  );
}
