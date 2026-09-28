"use client";

import { Outlet, useLocation, type ErrorComponentProps } from "@tanstack/react-router";
import { IsolatedErrorBoundary, RouteErrorView } from "@/app/components/error-boundary";
import { DashboardAuthRecovery, SignInRedirect } from "../components/auth-recovery";
import { isDashboardApiError } from "../lib/api";
import { shellRoute } from "../routes/root";
import { DashboardAccountMenu, DashboardAccountMenuFallback } from "./dashboard-account-menu";
import { DashboardShell } from "./dashboard-shell";

export function DashboardFrame() {
  const { session } = shellRoute.useRouteContext();
  return (
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
  );
}

/** Session failures: 401 goes to sign-in, a Stack outage renders recovery. */
export function DashboardFrameError({ error, reset }: ErrorComponentProps) {
  const location = useLocation();
  if (isDashboardApiError(error, 401)) return <SignInRedirect returnPath={location.href} />;
  if (isDashboardApiError(error, 503)) return <DashboardAuthRecovery returnPath={location.href} />;
  return <RouteErrorView boundary="dashboard-session" error={error} retry={reset} />;
}

/** Route-level failure inside the frame, so the sidebar stays usable. */
export function DashboardRouteError({ error, reset }: ErrorComponentProps) {
  return <RouteErrorView boundary="dashboard-route" error={error} retry={reset} />;
}
