"use client";

import posthog from "posthog-js";
import { useEffect } from "react";

/** Records one sanitized 404 view for the current locale. */
export function NotFoundAnalytics({ locale }: { locale: string }) {
  useEffect(() => {
    posthog.capture("cmuxterm_404_viewed", {
      locale,
      location: "not_found",
    });
  }, [locale]);

  return null;
}
