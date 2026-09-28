"use client";

import { useTranslations } from "next-intl";
import { SettingsPageHeader } from "../components/settings-ui";

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
