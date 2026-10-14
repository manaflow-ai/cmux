"use client";

import { Outlet } from "@tanstack/react-router";
import { Suspense } from "react";
import { IsolatedErrorBoundary } from "@/app/components/error-boundary";
import { SettingsSubnavLayout } from "@/dashboard-app/components/settings-ui";
import { SettingsNav, SettingsNavWithAccount } from "./settings-nav";

/**
 * The Settings hub frame: `/dashboard/settings/*`, `/dashboard/billing`, and
 * `/dashboard/teams/*`. The static navigation paints at once; the
 * API keys entry and the team list appear once the Stack project and user
 * resolve. The shell already gates the session.
 */
export function SettingsLayout() {
  return (
    <SettingsSubnavLayout
      testId="settings-hub"
      nav={
        <IsolatedErrorBoundary name="dashboard-settings-nav" fallback={<SettingsNav />}>
          <Suspense fallback={<SettingsNav />}>
            <SettingsNavWithAccount />
          </Suspense>
        </IsolatedErrorBoundary>
      }
    >
      <Outlet />
    </SettingsSubnavLayout>
  );
}
