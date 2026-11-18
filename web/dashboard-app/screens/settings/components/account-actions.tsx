"use client";

import { useStackApp, useUser } from "@hexclave/next";
import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";
import { useState } from "react";
import { signOutOfDashboard } from "@/dashboard-app/lib/sign-out";
import { AccountDeletionRequestError, deleteAccountThroughCmux, type AccountDeletionFailure } from "@/dashboard-app/lib/delete-account";
import {
  ConfirmDialog,
  InlineError,
  SettingsSection,
  SettingsStack,
  settingsButtonClass,
  useAsyncAction,
} from "@/dashboard-app/components/settings-ui";
import { settingsAccountDeletionQuery } from "@/dashboard-app/queries/settings";
import { AppStoreSubscriptionWarning } from "./app-store-subscription-warning";

const DELETE_ERROR_MESSAGE = {
  pending: "deleteErrorPending",
  retryable: "deleteErrorRetryable",
} as const satisfies Record<Exclude<AccountDeletionFailure, "failed" | "signed_out">, string>;

/** `/dashboard/settings/account`: billing link, sign out, delete account. */
export function AccountActions() {
  const t = useTranslations("dashboard.settings.account");
  const app = useStackApp();
  // Signed-out visitors go to sign-in.
  useUser({ or: "redirect" });
  const locale = useLocale();
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [runSignOut, signOutState] = useAsyncAction(t("signOutError"));
  // Read when the dialog opens (a reopen refetches; confirm waits for the
  // fresh answer). A failed read never blocks deletion: the dialog then
  // shows no App Store warning, as for a web subscriber.
  const deletionCheck = useQuery({ ...settingsAccountDeletionQuery, enabled: confirmingDelete, retry: false });

  // The same sign-out as the dashboard account menu.
  const signOut = () => runSignOut(() => signOutOfDashboard(app, locale));

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
      {/* Deletion runs on the server (DELETE /api/account), so the sign-in
          project's client-deletion setting no longer gates it. */}
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
          confirmDisabled={deletionCheck.isFetching}
          describeError={(error) =>
            error instanceof AccountDeletionRequestError && (error.reason === "pending" || error.reason === "retryable")
              ? t(DELETE_ERROR_MESSAGE[error.reason])
              : null}
          onConfirm={async () => {
            // The cmux deletion route, as on iPhone: it runs the cmux cleanup
            // and the App Store unlink, then deletes the sign-in account.
            // Then leave the way sign-out does. Ending the local session
            // of a deleted user may fail, which is fine.
            const leave = () => signOutOfDashboard({ signOut: () => app.signOut().catch(() => undefined) }, locale);
            try {
              await deleteAccountThroughCmux(app);
            } catch (error) {
              // The server no longer knows this session: most often an
              // earlier attempt whose connection dropped already deleted
              // the account. Nothing more can be done from this session.
              if (error instanceof AccountDeletionRequestError && error.reason === "signed_out") {
                await leave();
                return;
              }
              throw error;
            }
            await leave();
          }}
        >
          {deletionCheck.data?.appStoreSubscriptionRenews ? (
            <AppStoreSubscriptionWarning manageUrl={deletionCheck.data.manageSubscriptionsUrl} />
          ) : null}
        </ConfirmDialog>
      </SettingsSection>
    </SettingsStack>
  );
}
