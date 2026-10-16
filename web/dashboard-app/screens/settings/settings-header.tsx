"use client";

import type { ErrorComponentProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";
import { SettingsPageHeader } from "@/dashboard-app/components/settings-ui";

export type SettingsHeaderSection =
  | "profile"
  | "auth"
  | "notifications"
  | "sessions"
  | "apiKeys"
  | "account";

/** Static page title, rendered outside the private Suspense boundary. */
export function SettingsHeader({ section }: { readonly section: SettingsHeaderSection }) {
  const t = useTranslations(`dashboard.settings.${section}`);
  return <SettingsPageHeader title={t("title")} description={t("description")} />;
}

/** A settings page whose route failed: its header, then the error naming the page. */
export function SettingsRouteError({ section, ...props }: ErrorComponentProps & { readonly section: SettingsHeaderSection }) {
  const t = useTranslations(`dashboard.settings.${section}`);
  return (
    <>
      <SettingsHeader section={section} />
      <RouteSectionError {...props} section={t("title")} />
    </>
  );
}
