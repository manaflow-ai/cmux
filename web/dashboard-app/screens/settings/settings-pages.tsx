"use client";

import { Suspense, type ReactNode } from "react";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { AccountActions } from "./components/account-actions";
import { ApiKeySettings } from "./components/api-key-settings";
import { AuthSettings } from "./components/auth-settings";
import { NotificationSettings } from "./components/notification-settings";
import { ProfileSettings } from "./components/profile-settings";
import { SessionSettings } from "./components/session-settings";
import { SettingsHeader, type SettingsHeaderSection } from "./settings-header";

/**
 * A static header, then the section's Stack-backed content behind its own
 * error boundary, so one failing section leaves the navigation usable.
 */
function SettingsPage({ section, children }: { readonly section: SettingsHeaderSection; readonly children: ReactNode }) {
  return (
    <>
      <SettingsHeader section={section} />
      <IsolatedErrorBoundary name={`dashboard-settings-${section}`} fallback={<SectionUnavailable />}>
        <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>{children}</Suspense>
      </IsolatedErrorBoundary>
    </>
  );
}

export function SettingsProfilePage() {
  return <SettingsPage section="profile"><ProfileSettings /></SettingsPage>;
}

export function SettingsAuthPage() {
  return <SettingsPage section="auth"><AuthSettings /></SettingsPage>;
}

export function SettingsNotificationsPage() {
  return <SettingsPage section="notifications"><NotificationSettings /></SettingsPage>;
}

export function SettingsSessionsPage() {
  return <SettingsPage section="sessions"><SessionSettings /></SettingsPage>;
}

export function SettingsApiKeysPage() {
  return <SettingsPage section="apiKeys"><ApiKeySettings /></SettingsPage>;
}

export function SettingsAccountPage() {
  return <SettingsPage section="account"><AccountActions /></SettingsPage>;
}
