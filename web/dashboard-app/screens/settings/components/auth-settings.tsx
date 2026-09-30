"use client";

import { useStackApp, useUser } from "@hexclave/next";
import { Suspense } from "react";
import { IsolatedErrorBoundary } from "@/app/components/error-boundary";
import { SettingsStack } from "@/dashboard-app/components/settings-ui";
import { ConnectedAccountsSection } from "./auth/connected-accounts-section";
import { EmailsSection } from "./auth/emails-section";
import { MfaSection } from "./auth/mfa-section";
import { OtpSection } from "./auth/otp-section";
import { PasskeySection } from "./auth/passkey-section";
import { PasswordSection } from "./auth/password-section";

/** `/dashboard/settings/auth`: emails, sign-in methods, and MFA. */
export function AuthSettings() {
  const user = useUser({ or: "redirect" });
  const { config } = useStackApp().useProject();

  return (
    <div className="flex flex-col gap-6">
      <EmailsSection user={user} />
      <SettingsStack>
        {config.credentialEnabled ? <PasswordSection user={user} /> : null}
        {config.passkeyEnabled ? <PasskeySection user={user} /> : null}
        {config.magicLinkEnabled ? <OtpSection user={user} /> : null}
        <MfaSection user={user} />
      </SettingsStack>
      {/* An extra request; a failure here must not take down the page. */}
      <IsolatedErrorBoundary name="dashboard-settings-connected-accounts" fallback={null}>
        <Suspense fallback={null}>
          <ConnectedAccountsSection user={user} />
        </Suspense>
      </IsolatedErrorBoundary>
    </div>
  );
}
