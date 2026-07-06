"use client";

import posthog from "posthog-js";
import {
  pricingActionClassName,
  type PricingActionSize,
} from "../../components/pricing-shared";
import {
  isClientConfigFlagEnabled,
  useClientConfigFlag,
} from "../../lib/client-config-flags";
import { FEATURE_FLAGS } from "../../lib/feature-flags";

// Single evaluation site for the pro-checkout flag (lint-enforced).
// Resolution: build-time env force (local dev / previews), then the PostHog
// flag, then the registry's safe default (the download link always works,
// including while flags are still loading — no checkout flicker).
const FORCE = process.env.NEXT_PUBLIC_CMUX_CHECKOUT_ENABLED;
const FORCED_ON = FORCE === "1" || (FORCE === undefined && process.env.NODE_ENV === "development");
const FORCED_OFF = FORCE === "0";

export function ProCtaLink({
  checkoutHref,
  fallbackHref,
  children,
  size = "default",
  location = "pricing_page",
}: {
  checkoutHref: string;
  fallbackHref: string;
  children: React.ReactNode;
  size?: PricingActionSize;
  location?: string;
}) {
  const flagEnabled = useClientConfigFlag(FEATURE_FLAGS.proCheckout.key);
  const checkout =
    !FORCED_OFF &&
    (FORCED_ON ||
      isClientConfigFlagEnabled(
        flagEnabled,
        FEATURE_FLAGS.proCheckout.defaultWhenUnavailable,
      ));
  return (
    <a
      href={checkout ? checkoutHref : fallbackHref}
      onClick={() =>
        posthog.capture("cmuxterm_pro_cta_clicked", {
          location,
          checkout,
        })
      }
      className={pricingActionClassName("primary", size)}
      style={{ color: "var(--background)", textDecoration: "none" }}
    >
      {children}
    </a>
  );
}
