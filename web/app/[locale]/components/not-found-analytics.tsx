"use client";

import { useEffect, useRef } from "react";
import { posthog } from "../../lib/posthog-client";

/**
 * The root not-found route renders outside the locale provider. Re-open the
 * anonymous PostHog transport here so recovery clicks are not lost behind the
 * provider's identity-resolution gate.
 */
export function NotFoundAnalytics({ locale }: { locale: string }) {
  const captured = useRef(false);

  useEffect(() => {
    if (captured.current) return;
    captured.current = true;
    posthog.set_config({ before_send: (event) => event });
    const path = window.location.pathname;
    const properties = { location: "not_found", locale, path };
    posthog.capture("$pageview", { $current_url: window.location.href });
    posthog.capture("cmuxterm_404_viewed", properties);
  }, [locale]);

  return null;
}
