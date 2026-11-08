"use client";

import { useUser } from "@hexclave/next";
import { useSuspenseQuery } from "@tanstack/react-query";
import { Suspense } from "react";
import { IsolatedErrorBoundary } from "@/app/components/error-boundary";
import { SettingsStack } from "@/dashboard-app/components/settings-ui";
import { settingsOverviewQuery } from "@/dashboard-app/queries/settings";
import { ConnectedAccountsSection } from "./auth/connected-accounts-section";
import { EmailsSection } from "./auth/emails-section";
import { MfaSection } from "./auth/mfa-section";
import { OtpSection } from "./auth/otp-section";
import { PasskeySection } from "./auth/passkey-section";
import { PasswordSection } from "./auth/password-section";

/** `/dashboard/settings/auth`: emails, sign-in methods, and MFA. */
export function AuthSettings() {
  const user = useUser({ or: "redirect" });
  const { project: config, emails } = useSuspenseQuery(settingsOverviewQuery).data;

  return (
    <div className="flex flex-col gap-6">
      <EmailsSection user={user} channels={emails} />
      <SettingsStack>
        {config.credentialEnabled ? <PasswordSection user={user} channels={emails} /> : null}
        {config.passkeyEnabled ? <PasskeySection user={user} channels={emails} /> : null}
        {config.magicLinkEnabled ? <OtpSection user={user} channels={emails} /> : null}
        <MfaSection user={user} projectName={config.displayName} />
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
