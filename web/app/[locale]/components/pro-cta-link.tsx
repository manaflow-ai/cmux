"use client";

import posthog from "posthog-js";
import {
  pricingActionClassName,
  type PricingActionSize,
} from "../../components/pricing-shared";
import {
  CheckoutPendingContent,
  useCheckoutRedirect,
} from "../../components/checkout-navigation";

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
  const { pending, start } = useCheckoutRedirect();
  return (
    <a
      href={checkoutHref}
      onClick={(event) => {
        posthog.capture("cmuxterm_pro_cta_clicked", {
          location,
          checkout: true,
        });
        start(checkoutHref, event);
      }}
      aria-busy={pending}
      className={`${pricingActionClassName("primary", size)} relative`}
      style={{
        color: "var(--background)",
        textDecoration: "none",
        pointerEvents: pending ? "none" : undefined,
      }}
    >
      <CheckoutPendingContent pending={pending}>{children}</CheckoutPendingContent>
    </a>
  );
}
