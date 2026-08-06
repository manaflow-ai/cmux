"use client";

import { PostHogProvider as PHProvider } from "posthog-js/react";
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

  useLayoutEffect(() => {
    if (!pathname || !posthog) return;

    let activeController: AbortController | null = null;
    let generation = 0;
    let pageviewPending = true;
    const identityStorage = {
      getItem: (key: string) =>
        window.sessionStorage.getItem(key) ?? window.localStorage.getItem(key),
      setItem: (key: string, value: string) => {
        window.sessionStorage.setItem(key, value);
        window.localStorage.setItem(key, value);
      },
      removeItem: (key: string) => {
        window.sessionStorage.removeItem(key);
        window.localStorage.removeItem(key);
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
    const recoverAsAnonymous = () => {
      clearUnresolvedIdentity();
      posthog.set_config({ before_send: (event) => event });
      finishPendingPageview();
    };

    const resolveIdentity = async (gateWhilePending: boolean) => {
      const currentGeneration = ++generation;
      activeController?.abort();
      const controller = new AbortController();
      activeController = controller;
      let timedOut = false;
      const timeoutId = window.setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, 5_000);
      if (gateWhilePending) {
        // Auth changes close the gate immediately. Passive focus/online
        // refreshes keep an already-resolved identity live until they prove it
        // changed, so routine refocuses do not discard user events.
        posthog.set_config({ before_send: () => null });
      }

      try {
        const response = await fetch("/api/analytics/identity", {
          cache: "no-store",
          credentials: "same-origin",
          signal: controller.signal,
        });
        if (controller.signal.aborted || currentGeneration !== generation) return;
        if (!response.ok) {
          recoverAsAnonymous();
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
            recoverAsAnonymous();
            return;
          }
          identity = { id: payload.user.id, plan };
        }
        posthog.set_config({ before_send: (event) => event });
        syncStackAnalyticsIdentity(posthog, identityStorage, identity);
        finishPendingPageview();
      } catch {
        // Fail closed: an unresolved auth state must not attribute this route
        // or later autocapture to an identity retained from before a logout.
        if (
          currentGeneration === generation
          && (!controller.signal.aborted || timedOut)
        ) {
          recoverAsAnonymous();
        }
      } finally {
        window.clearTimeout(timeoutId);
        if (currentGeneration === generation) activeController = null;
      }
    };

    const revalidateVisibleIdentity = () => {
      if (document.visibilityState === "visible" && !activeController) {
        void resolveIdentity(false);
      }
    };
    const revalidateCrossTabIdentity = (event: StorageEvent) => {
      if (event.key === STACK_IDENTITY_STORAGE_KEY) void resolveIdentity(true);
    };
    const revalidateStackAuthIdentity = () => void resolveIdentity(true);

    // Route changes cover normal sign-in/sign-out redirects. Focus,
    // visibility, online, and storage events cover session expiry, account
    // changes without navigation, and changes made in another tab.
    void resolveIdentity(true);
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
