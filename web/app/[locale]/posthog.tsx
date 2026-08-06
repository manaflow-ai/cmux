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

    // Resolve auth before each route's pageview. This preserves anonymous
    // pre-sign-in history through identify(), and prevents the first pageview
    // after sign-out from remaining attached to the previous Stack account.
    void fetch("/api/analytics/identity", {
      cache: "no-store",
      credentials: "same-origin",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) return;
        const payload = await response.json() as {
          user?: { id?: unknown; plan?: unknown } | null;
        };
        const plan = payload.user?.plan;
        const identity: StackAnalyticsIdentity | null =
          typeof payload.user?.id === "string"
          && (plan === "free" || plan === "pro" || plan === "team")
          ? { id: payload.user.id, plan }
          : null;
        syncStackAnalyticsIdentity(posthog, window.localStorage, identity);
      })
      .catch(() => {
        // Preserve the current identity when auth lookup is unavailable.
      })
      .finally(() => {
        if (!controller.signal.aborted) capturePageview();
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
