"use client";

import { useUser, type CurrentUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { useState } from "react";
import { InlineError, SettingsPanel, SettingsSwitch } from "@/dashboard-app/components/settings-ui";

type NotificationCategory = ReturnType<CurrentUser["useNotificationCategories"]>[number];

/** `/dashboard/settings/notifications`: email category switches. */
export function NotificationSettings() {
  const t = useTranslations("dashboard.settings.notifications");
  const categories = useUser({ or: "redirect" }).useNotificationCategories();

  return (
    <SettingsPanel title={t("heading")}>
      {categories.length === 0 ? (
        <p className="text-xs text-muted">{t("empty")}</p>
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

function NotificationRow({ category }: { readonly category: NotificationCategory }) {
  const t = useTranslations("dashboard.settings.notifications");
  // The switch reflects the requested value while the update is in flight.
  const [optimistic, setOptimistic] = useState<boolean | null>(null);
  const [failed, setFailed] = useState(false);
  const checked = optimistic ?? category.enabled;

  const change = async (enabled: boolean) => {
    setOptimistic(enabled);
    setFailed(false);
    try {
      await category.setEnabled(enabled);
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
