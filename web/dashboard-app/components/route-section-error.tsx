"use client";

import { useQueryErrorResetBoundary } from "@tanstack/react-query";
import { type ErrorComponentProps, useLocation, useRouter } from "@tanstack/react-router";
import { reportBoundaryError } from "@/app/components/error-boundary";
import { isRefusal } from "../lib/refusal";
import { SignInRedirect } from "./auth-recovery";
import { SectionError } from "./page-states";

/**
 * Route `errorComponent` body. A 401 goes to sign-in; anything else shows
 * `SectionError` in place of the route's data, and Try again clears the
 * query errors and reruns the loaders.
 */
export function RouteSectionError({ error, reset, section }: ErrorComponentProps & { readonly section?: string }) {
  const router = useRouter();
  const location = useLocation();
  const queryErrors = useQueryErrorResetBoundary();
  if (isRefusal(error, 401)) return <SignInRedirect returnPath={location.href} />;
  return (
    <div
      ref={(node) => {
        if (node) reportBoundaryError("dashboard-route", error);
      }}
    >
      <SectionError
        error={error}
        section={section}
        onRetry={async () => {
          queryErrors.reset();
          await router.invalidate();
          reset();
        }}
      />
    </div>
  );
}
