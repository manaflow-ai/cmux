"use client";

import posthog from "posthog-js";
import { useFeatureFlagEnabled } from "posthog-js/react";
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
}: {
  checkoutHref: string;
  fallbackHref: string;
  children: React.ReactNode;
}) {
  const flagEnabled = useFeatureFlagEnabled(FEATURE_FLAGS.proCheckout.key);
  const checkout =
    !FORCED_OFF &&
    (FORCED_ON ||
      (flagEnabled ?? FEATURE_FLAGS.proCheckout.defaultWhenUnavailable));
  return (
    <a
      href={checkout ? checkoutHref : fallbackHref}
      onClick={() =>
        posthog.capture("cmuxterm_pro_cta_clicked", {
          location: "pricing_page",
          checkout,
        })
      }
      className="inline-flex w-full items-center justify-center whitespace-nowrap bg-foreground px-5 py-2.5 text-[15px] font-medium hover:opacity-85 transition-opacity"
      style={{ color: "var(--background)", textDecoration: "none" }}
    >
      {children}
    </a>
  );
}
