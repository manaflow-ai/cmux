"use client";

import { useStackApp, useUser } from "@hexclave/next";
import { Link } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";
import { useState } from "react";
import { clearCoderouterOrganizationScope } from "@/services/coderouter/organizationScope";
import {
  ConfirmDialog,
  InlineError,
  SettingsSection,
  SettingsStack,
  settingsButtonClass,
  useAsyncAction,
} from "@/dashboard-app/components/settings-ui";
import { localeHomeHref } from "@/dashboard-app/lib/locale-href";

/** `/dashboard/settings/account`: billing link, sign out, delete account. */
export function AccountActions() {
  const t = useTranslations("dashboard.settings.account");
  const app = useStackApp();
  const project = app.useProject();
  const user = useUser({ or: "redirect" });
  const locale = useLocale();
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [runSignOut, signOutState] = useAsyncAction(t("signOutError"));

  // Same sequence as the dashboard account menu, so both entrypoints clear
  // the coderouter organization scope.
  const signOut = () =>
    runSignOut(async () => {
      await app.signOut();
      clearCoderouterOrganizationScope();
      // Home is outside the SPA; a document load also drops every cached query.
      window.location.assign(localeHomeHref(locale));
    });

  return (
    <SettingsStack>
      <SettingsSection title={t("billingTitle")} description={t("billingDescription")}>
        <Link to="/dashboard/billing" className={settingsButtonClass("secondary", "sm")}>
          {t("billingLink")}
        </Link>
      </SettingsSection>
      <SettingsSection title={t("signOutTitle")} description={t("signOutDescription")}>
        <button
          type="button"
          disabled={signOutState.pending}
          onClick={() => void signOut()}
          className={settingsButtonClass("secondary", "sm")}
        >
          {signOutState.pending ? t("signingOut") : t("signOut")}
        </button>
        <InlineError message={signOutState.error} />
      </SettingsSection>
      {project.config.clientUserDeletionEnabled ? (
        <SettingsSection tone="danger" title={t("deleteTitle")} description={t("deleteDescription")}>
          <button type="button" onClick={() => setConfirmingDelete(true)} className={settingsButtonClass("danger", "sm")}>
            {t("delete")}
          </button>
          <ConfirmDialog
            open={confirmingDelete}
            onOpenChange={setConfirmingDelete}
            title={t("deleteConfirmTitle")}
            description={t("deleteConfirmBody")}
            acknowledgement={t("deleteAcknowledge")}
            confirmLabel={t("deleteConfirm")}
            errorMessage={t("deleteError")}
            onConfirm={async () => {
              await user.delete();
              clearCoderouterOrganizationScope();
              await app.redirectToHome();
            }}
          />
        </SettingsSection>
      ) : null}
    </SettingsStack>
  );
}
