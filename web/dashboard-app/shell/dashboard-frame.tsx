"use client";

import { Outlet, useLocation, type ErrorComponentProps } from "@tanstack/react-router";
import { IsolatedErrorBoundary } from "@/app/components/error-boundary";
import { DashboardAuthRecovery, SignInRedirect } from "../components/auth-recovery";
import { RouteSectionError } from "../components/route-section-error";
import { isRefusal } from "../lib/refusal";
import { shellRoute } from "../routes/root";
import { DashboardAccountMenu, DashboardAccountMenuFallback } from "./dashboard-account-menu";
import { DashboardShell } from "./dashboard-shell";
import { DashboardTitle } from "./dashboard-title";

export function DashboardFrame() {
  const { session } = shellRoute.useRouteContext();
  return (
    <>
      <DashboardTitle />
      <DashboardShell
        vaultEnabled={session.flags.vaultEnabled}
        account={
          <IsolatedErrorBoundary name="dashboard-account-menu" fallback={<DashboardAccountMenuFallback />}>
            <DashboardAccountMenu user={session.user} />
          </IsolatedErrorBoundary>
        }
      >
        <Outlet />
      </DashboardShell>
    </>
  );
}

/**
 * Failures of the session load itself (the shell's `beforeLoad`): 401 goes to
 * sign-in, a Stack outage renders sign-in recovery. Data failures below the
 * shell never reach here; each route shows `SectionError` in its own frame.
 */
export function DashboardFrameError(props: ErrorComponentProps) {
  const location = useLocation();
  if (isRefusal(props.error, 401)) return <SignInRedirect returnPath={location.href} />;
  if (isRefusal(props.error, 503)) return <DashboardAuthRecovery returnPath={location.href} />;
  return <DashboardRouteError {...props} />;
}

/**
 * Default route failure inside the frame for routes without their own page
 * frame: the sidebar stays usable and the failure reads like every other
 * data region.
 */
export function DashboardRouteError(props: ErrorComponentProps) {
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <RouteSectionError {...props} />
    </div>
  );
}
