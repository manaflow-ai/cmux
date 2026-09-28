"use client";

import type { CurrentUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { useState } from "react";
import {
  ConfirmDialog,
  InlineError,
  SettingsNotice,
  SettingsSection,
  settingsButtonClass,
  useAsyncAction,
} from "../../../components/settings-ui";
import { hasVerifiedSignInEmail } from "../../lib/contact-channels";
import { isOnlySignInMethod } from "../../lib/sign-in-methods";
import { signInFacts } from "./sign-in-facts";

/** Register or disable passkey sign-in. Rendered when passkeys are enabled. */
export function PasskeySection({ user }: { readonly user: CurrentUser }) {
  const t = useTranslations("dashboard.settings.auth.passkey");
  const channels = user.useContactChannels();
  const [confirming, setConfirming] = useState(false);
  const [run, state] = useAsyncAction(t("registerError"));
  const hasPasskey = user.passkeyAuthEnabled;
  const isLast = isOnlySignInMethod("passkey", signInFacts(user));

  const register = () =>
    run(async () => {
      // Hexclave ignored this Result, so a cancelled or failed WebAuthn
      // ceremony looked like success. Surface it instead.
      const result = await user.registerPasskey();
      if (result.status === "error") throw result.error;
    });

  return (
    <SettingsSection title={t("title")} description={hasPasskey ? t("registered") : t("notRegistered")}>
      <PasskeyControls
        hasValidEmail={hasVerifiedSignInEmail(channels)}
        hasPasskey={hasPasskey}
        isLast={isLast}
        pending={state.pending}
        onRegister={() => void register()}
        onDisable={() => setConfirming(true)}
      />
      <InlineError message={state.error} />
      <ConfirmDialog
        open={confirming}
        onOpenChange={setConfirming}
        title={t("disableTitle")}
        description={t("disableBody")}
        confirmLabel={t("disable")}
        errorMessage={t("disableError")}
        onConfirm={() => user.update({ passkeyAuthEnabled: false })}
      />
    </SettingsSection>
  );
}

function PasskeyControls({
  hasValidEmail,
  hasPasskey,
  isLast,
  pending,
  onRegister,
  onDisable,
}: {
  readonly hasValidEmail: boolean;
  readonly hasPasskey: boolean;
  readonly isLast: boolean;
  readonly pending: boolean;
  readonly onRegister: () => void;
  readonly onDisable: () => void;
}) {
  const t = useTranslations("dashboard.settings.auth.passkey");
  if (!hasValidEmail) return <SettingsNotice>{t("needsVerifiedEmail")}</SettingsNotice>;
  if (!hasPasskey) {
    return (
      <button type="button" disabled={pending} onClick={onRegister} className={settingsButtonClass("secondary", "sm")}>
        {pending ? t("registering") : t("add")}
      </button>
    );
  }
  if (isLast) return <SettingsNotice>{t("onlyMethod")}</SettingsNotice>;
  return (
    <button type="button" onClick={onDisable} className={settingsButtonClass("secondary", "sm")}>
      {t("delete")}
    </button>
  );
}
