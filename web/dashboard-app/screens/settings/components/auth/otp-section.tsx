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
} from "@/dashboard-app/components/settings-ui";
import { hasVerifiedSignInEmail } from "../../lib/contact-channels";
import { isOnlySignInMethod } from "../../lib/sign-in-methods";
import { signInFacts } from "./sign-in-facts";
import type { SettingsEmail } from "@/dashboard-app/queries/settings";

/** Magic link / OTP sign-in toggle. Rendered when magic links are enabled. */
export function OtpSection({
  user,
  channels,
}: {
  readonly user: CurrentUser;
  readonly channels: readonly SettingsEmail[];
}) {
  const t = useTranslations("dashboard.settings.auth.otp");
  const [confirming, setConfirming] = useState(false);
  const [run, state] = useAsyncAction(t("enableError"));
  const enabled = user.otpAuthEnabled;
  const isLast = isOnlySignInMethod("otp", signInFacts(user));

  const controls = (() => {
    if (!hasVerifiedSignInEmail(channels)) return <SettingsNotice>{t("needsVerifiedEmail")}</SettingsNotice>;
    if (!enabled) {
      return (
        <button
          type="button"
          disabled={state.pending}
          onClick={() => void run(() => user.update({ otpAuthEnabled: true }))}
          className={settingsButtonClass("secondary", "sm")}
        >
          {t("enable")}
        </button>
      );
    }
    if (isLast) return <SettingsNotice>{t("onlyMethod")}</SettingsNotice>;
    return (
      <button type="button" onClick={() => setConfirming(true)} className={settingsButtonClass("secondary", "sm")}>
        {t("disable")}
      </button>
    );
  })();

  return (
    <SettingsSection title={t("title")} description={enabled ? t("enabledDescription") : t("disabledDescription")}>
      {controls}
      <InlineError message={state.error} />
      <ConfirmDialog
        open={confirming}
        onOpenChange={setConfirming}
        title={t("disableTitle")}
        description={t("disableBody")}
        confirmLabel={t("disableConfirm")}
        errorMessage={t("disableError")}
        onConfirm={() => user.update({ otpAuthEnabled: false })}
      />
    </SettingsSection>
  );
}
