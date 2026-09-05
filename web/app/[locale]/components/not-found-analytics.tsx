"use client";

import { useEffect, useRef } from "react";
import { usePathname } from "next/navigation";
import { posthog } from "../../lib/posthog-client";

/**
 * The root not-found route renders outside the locale provider. Re-open the
 * anonymous PostHog transport here so recovery clicks are not lost behind the
 * provider's identity-resolution gate.
 */
export function NotFoundAnalytics({ locale }: { locale: string }) {
  const pathname = usePathname();
  const capturedKey = useRef<string | null>(null);

  useEffect(() => {
    const key = `${locale}:${pathname}`;
    if (capturedKey.current === key) return;
    capturedKey.current = key;
    posthog.set_config({
      before_send: (event) => {
        if (!event) return null;
        const properties = { ...event.properties };
        delete properties.$current_url;
        delete properties.$pathname;
        delete properties.$referrer;
        return { ...event, properties };
      },
    });
    const properties = { location: "not_found", locale };
    posthog.capture("cmuxterm_404_viewed", properties);
  }, [locale, pathname]);

  return null;
}
