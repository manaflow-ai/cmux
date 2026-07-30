"use client";

import { posthog } from "../../lib/posthog-client";
import {
  pricingActionClassName,
  type PricingActionSize,
} from "../../components/pricing-shared";
import {
  CheckoutPendingContent,
  useCheckoutRedirect,
} from "../../components/checkout-navigation";
import {
  PRO_PRICING_USD,
  type ProBillingInterval,
} from "../../../services/billing/plans";

export function ProCtaLink({
  checkoutHref,
  children,
  size = "default",
  location = "pricing_page",
  interval = "month",
}: {
  checkoutHref: string;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
  interval?: ProBillingInterval;
}) {
  const { pending, start } = useCheckoutRedirect();
  const pricing = PRO_PRICING_USD[interval];
  return (
    <a
      href={checkoutHref}
      onClick={(event) => {
        posthog.capture("cmuxterm_pro_cta_clicked", {
          location,
          checkout: true,
          interval,
          currency: "usd",
          billed_amount_usd: pricing.billedAmount,
          monthly_equivalent_usd: pricing.monthlyEquivalent,
          discount_percent: pricing.discountPercent,
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
