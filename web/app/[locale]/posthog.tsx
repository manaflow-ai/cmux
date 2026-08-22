"use client";

import { PostHogProvider as PHProvider } from "posthog-js/react";
import type { CaptureResult } from "posthog-js";
import { useUser } from "@stackframe/stack";
import { usePathname, useSearchParams } from "next/navigation";
import { useLayoutEffect, useRef, Suspense } from "react";
import { posthog } from "../lib/posthog-client";
import {
  STACK_IDENTITY_STORAGE_KEY,
  syncStackAnalyticsIdentity,
  type StackAnalyticsIdentity,
} from "../../services/analytics/stackIdentity";

const STACK_AUTH_CHANGED_EVENT = "cmux:stack-auth-changed";

function PageviewTracker() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const lastCapturedUrl = useRef<string | null>(null);
  const pendingCaptures = useRef<CaptureResult[]>([]);

  useLayoutEffect(() => {
    if (!pathname || !posthog) return;

    let activeController: AbortController | null = null;
    let generation = 0;
    let pageviewPending = true;
    const identityStorage = {
      getItem: (key: string) => {
        try {
          const sessionValue = window.sessionStorage.getItem(key);
          if (sessionValue) return sessionValue;
        } catch {
          // Try the independent persistent store below.
        }
        try {
          return window.localStorage.getItem(key);
        } catch {
          return null;
        }
      },
      setItem: (key: string, value: string) => {
        let persisted = false;
        try {
          window.sessionStorage.setItem(key, value);
          persisted = true;
        } catch {
          // Try the independent persistent store below.
        }
        try {
          window.localStorage.setItem(key, value);
          persisted = true;
        } catch {
          // One successful store is sufficient for logout recovery.
        }
        if (!persisted) throw new Error("Analytics identity storage unavailable");
      },
      removeItem: (key: string) => {
        try {
          window.sessionStorage.removeItem(key);
        } catch {
          // Best-effort after PostHog has already reset.
        }
        try {
          window.localStorage.removeItem(key);
        } catch {
          // Best-effort after PostHog has already reset.
        }
      },
    };
    const capturePageview = () => {
      let url = window.origin + pathname;
      const search = searchParams.toString();
      if (search) url += "?" + search;
      if (lastCapturedUrl.current === url) return;
      lastCapturedUrl.current = url;
      posthog.capture("$pageview", { $current_url: url });
    };
    const clearUnresolvedIdentity = () => {
      syncStackAnalyticsIdentity(posthog, identityStorage, null);
    };
    const finishPendingPageview = () => {
      if (!pageviewPending) return;
      pageviewPending = false;
      capturePageview();
    };
    const bufferCapture = (capture: CaptureResult | null) => {
      if (capture && pendingCaptures.current.length < 100) {
        pendingCaptures.current.push(capture);
      }
      return null;
    };
    const flushBufferedCaptures = (replay: boolean) => {
      const captures = pendingCaptures.current.splice(0);
      if (!replay) return;
      for (const capture of captures) {
        const properties = { ...capture.properties };
        for (const identityProperty of [
          "distinct_id",
          "$device_id",
          "$user_id",
          "$anon_distinct_id",
          "$had_persisted_distinct_id",
          "$groups",
        ]) {
          delete properties[identityProperty];
        }
        posthog.capture(capture.event, properties, {
          timestamp: capture.timestamp,
        });
      }
    };
    const recoverAsAnonymous = (replayBuffered: boolean) => {
      clearUnresolvedIdentity();
      posthog.set_config({ before_send: (event) => event });
      flushBufferedCaptures(replayBuffered);
      finishPendingPageview();
    };

    const resolveIdentity = async () => {
      const previousPostHogUserId = posthog.get_property("stack_user_id");
      const hadAuthenticatedIdentity = typeof previousPostHogUserId === "string";
      const currentGeneration = ++generation;
      activeController?.abort();
      const controller = new AbortController();
      activeController = controller;
      let timedOut = false;
      const timeoutId = window.setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, 5_000);
      // Buffer events until the server-confirmed identity is known. Replaying
      // after reset/identify prevents stale attribution without losing routine
      // focus and visibility captures.
      posthog.set_config({ before_send: bufferCapture });

      try {
        const response = await fetch("/api/analytics/identity", {
          cache: "no-store",
          credentials: "same-origin",
          signal: controller.signal,
        });
        if (controller.signal.aborted || currentGeneration !== generation) return;
        if (!response.ok) {
          recoverAsAnonymous(!hadAuthenticatedIdentity);
          return;
        }
        const payload = await response.json() as {
          user?: { id?: unknown; plan?: unknown } | null;
        };
        if (controller.signal.aborted || currentGeneration !== generation) return;
        let identity: StackAnalyticsIdentity | null;
        if (payload.user === null) {
          identity = null;
        } else {
          const plan = payload.user?.plan;
          if (
            typeof payload.user?.id !== "string"
            || (plan !== "free" && plan !== "pro" && plan !== "team")
          ) {
            recoverAsAnonymous(!hadAuthenticatedIdentity);
            return;
          }
          identity = { id: payload.user.id, plan };
        }
        posthog.set_config({ before_send: (event) => event });
        syncStackAnalyticsIdentity(posthog, identityStorage, identity);
        const identityUnchanged = !hadAuthenticatedIdentity
          || identity?.id === previousPostHogUserId;
        flushBufferedCaptures(identityUnchanged);
        finishPendingPageview();
      } catch {
        // Fail closed: an unresolved auth state must not attribute this route
        // or later autocapture to an identity retained from before a logout.
        if (
          currentGeneration === generation
          && (!controller.signal.aborted || timedOut)
        ) {
          recoverAsAnonymous(!hadAuthenticatedIdentity);
        }
      } finally {
        window.clearTimeout(timeoutId);
        if (currentGeneration === generation) activeController = null;
      }
    };

    const revalidateVisibleIdentity = () => {
      if (document.visibilityState === "visible" && !activeController) {
        void resolveIdentity();
      }
    };
    const revalidateCrossTabIdentity = (event: StorageEvent) => {
      if (event.key === STACK_IDENTITY_STORAGE_KEY) void resolveIdentity();
    };
    const revalidateStackAuthIdentity = () => void resolveIdentity();

    // Route changes cover normal sign-in/sign-out redirects. Focus,
    // visibility, online, and storage events cover session expiry, account
    // changes without navigation, and changes made in another tab.
    void resolveIdentity();
    window.addEventListener("focus", revalidateVisibleIdentity);
    window.addEventListener("online", revalidateVisibleIdentity);
    window.addEventListener("storage", revalidateCrossTabIdentity);
    window.addEventListener(STACK_AUTH_CHANGED_EVENT, revalidateStackAuthIdentity);
    document.addEventListener("visibilitychange", revalidateVisibleIdentity);

    return () => {
      generation += 1;
      activeController?.abort();
      window.removeEventListener("focus", revalidateVisibleIdentity);
      window.removeEventListener("online", revalidateVisibleIdentity);
      window.removeEventListener("storage", revalidateCrossTabIdentity);
      window.removeEventListener(STACK_AUTH_CHANGED_EVENT, revalidateStackAuthIdentity);
      document.removeEventListener("visibilitychange", revalidateVisibleIdentity);
    };
  }, [pathname, searchParams]);

  return null;
}

function StackAuthObserver() {
  const authenticatedUser = useUser({ or: "return-null" });
  const previousUserId = useRef<string | undefined>(undefined);
  const initialized = useRef(false);

  useLayoutEffect(() => {
    const userId = authenticatedUser?.id;
    if (!initialized.current) {
      initialized.current = true;
      previousUserId.current = userId;
      return;
    }
    if (previousUserId.current !== userId) {
      previousUserId.current = userId;
      window.dispatchEvent(new Event(STACK_AUTH_CHANGED_EVENT));
    }
  }, [authenticatedUser?.id]);

  return null;
}

export function PostHogProvider({
  children,
  observesStackAuth = false,
}: {
  children: React.ReactNode;
  observesStackAuth?: boolean;
}) {
  return (
    <PHProvider client={posthog}>
      <Suspense fallback={null}>
        <PageviewTracker />
      </Suspense>
      {observesStackAuth ? (
        <Suspense fallback={null}>
          <StackAuthObserver />
        </Suspense>
      ) : null}
      {children}
    </PHProvider>
  );
}
