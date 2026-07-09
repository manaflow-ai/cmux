"use client";

import posthog from "posthog-js";
import { PostHogProvider as PHProvider } from "posthog-js/react";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";
import { captureAnalyticsClick } from "../lib/analytics";

if (typeof window !== "undefined") {
  posthog.init("phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP", {
    api_host: "/api/analytics/posthog-sdk-disabled",
    ui_host: "https://us.posthog.com",
    autocapture: false,
    person_profiles: "identified_only",
    capture_pageview: false,
    capture_pageleave: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_external_dependency_loading: true,
    advanced_disable_flags: true,
    advanced_disable_decide: true,
    advanced_disable_feature_flags: true,
  });
}

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (pathname && posthog) {
      let url = window.origin + pathname;
      const search = searchParams.toString();
      if (search) url += "?" + search;
      captureAnalyticsClick("$pageview", { $current_url: url });
    }
  }, [pathname, searchParams]);

  return null;
}

export function PostHogProvider({ children }: { children: React.ReactNode }) {
  return (
    <PHProvider client={posthog}>
      <Suspense fallback={null}>
        <PageviewTracker />
      </Suspense>
      {children}
    </PHProvider>
  );
}
