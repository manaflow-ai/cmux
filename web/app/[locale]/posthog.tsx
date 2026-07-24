"use client";

import posthog from "posthog-js";
import { PostHogProvider as PHProvider } from "posthog-js/react";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";

import {
  analyticsPropertiesContainSharePath,
  containsPrivateSharePath,
  shouldInitializeAnalytics,
} from "@/services/analytics/sharePrivacy";

// A share code is an invitation credential. Avoid even initializing the
// analytics client on a direct share-page load, so bootstrap/config traffic
// cannot observe that URL. `before_send` also covers client-side navigation
// into a share page after analytics was initialized elsewhere.
if (
  typeof window !== "undefined" &&
  shouldInitializeAnalytics(window.location.pathname)
) {
  posthog.init("phc_opOVu7oFzR9wD3I6ZahFGOV2h3mqGpl5EHyQvmHciDP", {
    api_host: "https://r.cmux.com",
    ui_host: "https://us.posthog.com",
    person_profiles: "identified_only",
    capture_pageview: false,
    capture_pageleave: true,
    advanced_disable_feature_flags: true,
    before_send: (capture) => {
      if (
        capture === null ||
        containsPrivateSharePath(window.location.pathname) ||
        analyticsPropertiesContainSharePath(capture.properties)
      ) {
        return null;
      }
      return capture;
    },
  });
}

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (pathname && !containsPrivateSharePath(pathname) && posthog) {
      let url = window.origin + pathname;
      const search = searchParams.toString();
      if (search) url += "?" + search;
      posthog.capture("$pageview", { $current_url: url });
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
