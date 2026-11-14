"use client";

import { useTranslations } from "next-intl";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui";

const APPLE_MANAGE_SUBSCRIPTIONS_URL = "https://apps.apple.com/account/subscriptions";

/**
 * Deleting the account does not cancel an App Store subscription
 * (Guideline 5.1.1(v)): Apple keeps charging until it is cancelled there.
 */
export function AppStoreSubscriptionWarning({ manageUrl }: { readonly manageUrl: string | null }) {
  const t = useTranslations("dashboard.settings.account");
  return (
    <div
      role="note"
      data-testid="account-delete-app-store-warning"
      className="space-y-2 border border-amber-500/40 bg-amber-500/10 p-3 text-xs"
    >
      <p className="font-medium">{t("deleteAppStoreTitle")}</p>
      <p className="text-muted">{t("deleteAppStoreBody")}</p>
      <a
        href={manageUrl ?? APPLE_MANAGE_SUBSCRIPTIONS_URL}
        target="_blank"
        rel="noreferrer"
        className={settingsButtonClass("secondary", "sm")}
      >
        {t("deleteAppStoreManage")}
      </a>
    </div>
  );
}
