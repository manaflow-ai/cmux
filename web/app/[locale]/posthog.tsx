"use client";

import { PostHogProvider as PHProvider } from "posthog-js/react";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";
import { posthog } from "../lib/posthog-client";
import { syncStackAnalyticsIdentity } from "../../services/analytics/stackIdentity";

function StackIdentityTracker() {
  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/analytics/identity", {
      cache: "no-store",
      credentials: "same-origin",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) return;
        const payload = await response.json() as {
          user?: { id?: unknown } | null;
        };
        const identity = typeof payload.user?.id === "string"
          ? { id: payload.user.id }
          : null;
        syncStackAnalyticsIdentity(posthog, window.localStorage, identity);
      })
      .catch(() => {
        // Preserve the current identity when auth lookup is unavailable.
      });
    return () => controller.abort();
  }, []);

  return null;
}

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();

  useEffect(() => {
    if (pathname && posthog) {
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
      <StackIdentityTracker />
      <Suspense fallback={null}>
        <PageviewTracker />
      </Suspense>
      {children}
    </PHProvider>
  );
}
