"use client";

import { useUser } from "@hexclave/next";
import { Suspense, useLayoutEffect, useRef } from "react";
import { STACK_AUTH_CHANGED_EVENT } from "../../services/analytics/stackIdentity";
import { IsolatedErrorBoundary } from "../components/error-boundary";

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

/**
 * Tells the analytics identity tracker when the Hexclave session changes
 * without a navigation. `useUser` throws when a Hexclave request fails, even
 * with `or: "return-null"`, so the observer fails silently on its own
 * instead of unmounting the page.
 */
export function IsolatedStackAuthObserver() {
  return (
    <IsolatedErrorBoundary name="stack-auth-observer" fallback={null}>
      <Suspense fallback={null}>
        <StackAuthObserver />
      </Suspense>
    </IsolatedErrorBoundary>
  );
}
