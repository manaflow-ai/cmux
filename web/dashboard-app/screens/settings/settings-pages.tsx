"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { QuerySection } from "@/dashboard-app/components/page-states";
import { AccountActions } from "./components/account-actions";
import { ApiKeySettings } from "./components/api-key-settings";
import { AuthSettings } from "./components/auth-settings";
import { NotificationSettings } from "./components/notification-settings";
import { ProfileSettings } from "./components/profile-settings";
import { SessionSettings } from "./components/session-settings";
import { SettingsHeader, type SettingsHeaderSection } from "./settings-header";

/**
 * A static header, then the section's data behind `QuerySection`: a skeleton
 * while it loads, and `SectionError` with Try again if it fails, so one
 * failing section leaves the navigation usable.
 */
function SettingsPage({ section, children }: { readonly section: SettingsHeaderSection; readonly children: ReactNode }) {
  const t = useTranslations(`dashboard.settings.${section}`);
  return (
    <>
      <SettingsHeader section={section} />
      <QuerySection name={`dashboard-settings-${section}`} section={t("title")} skeleton={<DashboardSectionSkeleton variant="settings" />}>
        {children}
      </QuerySection>
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
