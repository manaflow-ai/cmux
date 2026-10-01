"use client";

import { useUser } from "@hexclave/next";
import { useSuspenseQuery } from "@tanstack/react-query";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { EmptyState } from "@/dashboard-app/components/page-states";
import { InlineError, SettingsPanel, SettingsSwitch } from "@/dashboard-app/components/settings-ui";
import {
  type SettingsNotificationCategory,
  settingsNotificationsQuery,
  useRefreshSettings,
} from "@/dashboard-app/queries/settings";

/** `/dashboard/settings/notifications`: email category switches. */
export function NotificationSettings() {
  const t = useTranslations("dashboard.settings.notifications");
  const categories = useSuspenseQuery(settingsNotificationsQuery).data;

  return (
    <SettingsPanel title={t("heading")}>
      {categories.length === 0 ? (
        <EmptyState title={t("empty")} />
      ) : (
        <ul className="divide-y divide-border border border-border">
          {categories.map((category) => (
            <NotificationRow key={category.id} category={category} />
          ))}
        </ul>
      )}
    </SettingsPanel>
  );
}

function NotificationRow({ category }: { readonly category: SettingsNotificationCategory }) {
  const t = useTranslations("dashboard.settings.notifications");
  const user = useUser({ or: "redirect" });
  const refresh = useRefreshSettings();
  // The switch reflects the requested value while the update is in flight.
  const [optimistic, setOptimistic] = useState<boolean | null>(null);
  const [failed, setFailed] = useState(false);
  const checked = optimistic ?? category.enabled;

  const change = async (enabled: boolean) => {
    setOptimistic(enabled);
    setFailed(false);
    try {
      // The SDK category, so the write runs with the user's own session.
      const sdk = (await user.listNotificationCategories()).find((candidate) => candidate.id === category.id);
      if (!sdk) throw new Error("notification_category_not_found");
      await sdk.setEnabled(enabled);
      await refresh();
    } catch {
      setFailed(true);
    } finally {
      setOptimistic(null);
    }
  };

  return (
    <li className="flex flex-col gap-1 px-3 py-2">
      <div className="flex items-center gap-3">
        <SettingsSwitch
          checked={checked}
          label={category.name}
          disabled={!category.canDisable || optimistic !== null}
          onCheckedChange={(enabled) => void change(enabled)}
        />
        <span>{category.name}</span>
        {!category.canDisable ? <span className="text-xs text-muted">{t("cannotDisable")}</span> : null}
      </div>
      <InlineError message={failed ? t("saveError") : null} />
    </li>
  );
}
