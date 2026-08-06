"use client";

import { PostHogProvider as PHProvider } from "posthog-js/react";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";
import { posthog } from "../lib/posthog-client";
import {
  syncStackAnalyticsIdentity,
  type StackAnalyticsIdentity,
} from "../../services/analytics/stackIdentity";

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (!pathname || !posthog) return;

    const controller = new AbortController();
    const capturePageview = () => {
      let url = window.origin + pathname;
      const search = searchParams.toString();
      if (search) url += "?" + search;
      posthog.capture("$pageview", { $current_url: url });
    };
    const clearUnresolvedIdentity = () => {
      syncStackAnalyticsIdentity(posthog, window.localStorage, null);
    };

    // Resolve auth before each route's pageview. This preserves anonymous
    // pre-sign-in history through identify(), and prevents the first pageview
    // after sign-out from remaining attached to the previous Stack account.
    void fetch("/api/analytics/identity", {
      cache: "no-store",
      credentials: "same-origin",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) {
          clearUnresolvedIdentity();
          return;
        }
        const payload = await response.json() as {
          user?: { id?: unknown; plan?: unknown } | null;
        };
        let identity: StackAnalyticsIdentity | null;
        if (payload.user === null) {
          identity = null;
        } else {
          const plan = payload.user?.plan;
          if (
            typeof payload.user?.id !== "string"
            || (plan !== "free" && plan !== "pro" && plan !== "team")
          ) {
            clearUnresolvedIdentity();
            return;
          }
          identity = { id: payload.user.id, plan };
        }
        syncStackAnalyticsIdentity(posthog, window.localStorage, identity);
        if (!controller.signal.aborted) capturePageview();
      })
      .catch(() => {
        // Fail closed: an unresolved auth state must not attribute this route
        // or later autocapture to an identity retained from before a logout.
        if (!controller.signal.aborted) clearUnresolvedIdentity();
      });

    return () => controller.abort();
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
