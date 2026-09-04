import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { verifyPasswordResetCode } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import {
  authErrorKeyForCode,
  parseAuthErrorKey,
} from "../../../services/auth/hexclave/errorCodes";
import { authPageHref, safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { AuthCard, AuthError } from "../components/auth-card";
import { authErrorMessage, firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";
import { HiddenReturnTo, PrimaryButton, TextField } from "../components/auth-fields";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  // Neutral on purpose: this route also renders the expired-link state, and
  // metadata is produced before the code is checked.
  return { title: intl.t("forgotTitle"), robots: { index: false, follow: false } };
}

export default async function PasswordResetPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  const config = hexclaveClientConfig();
  if (!config) notFound();

  const [params, intl] = await Promise.all([searchParams, authIntl()]);
  const rawReturnTo = firstParam(params.after_auth_return_to);
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const code = firstParam(params.code);
  const done = firstParam(params.done) === "1";

  const backToSignIn = (
    <Link
      className="text-foreground underline decoration-link-underline underline-offset-2"
      href={authPageHref("/handler/sign-in", { returnTo, method: "password" })}
    >
      {intl.t("backToSignIn")}
    </Link>
  );

  if (done) {
    return (
      <AuthCard
        intl={intl}
        title={intl.t("resetDoneTitle")}
        subtitle={intl.t("resetDoneBody")}
        footer={backToSignIn}
      >
        <span />
      </AuthCard>
    );
  }

  // The link's code is checked before the form renders, so an expired link
  // says so immediately instead of after the visitor has picked a password.
  const reportedError = parseAuthErrorKey(firstParam(params.error));
  const linkError = !code || !isResetCodeShaped(code)
    ? "invalidCode"
    // A reported form error means this code was accepted moments ago. Checking
    // it again on every rejected password would spend the code's limited
    // attempts on a visitor who is only retyping.
    : reportedError
      ? null
      : await checkResetCode(config, code);

  if (linkError) {
    return (
      <AuthCard
        intl={intl}
        title={intl.t("verifyFailedTitle")}
        subtitle={intl.t("verifyFailedBody")}
        footer={backToSignIn}
      >
        <span />
      </AuthCard>
    );
  }

  return (
    <AuthCard
      intl={intl}
      title={intl.t("resetTitle")}
      subtitle={intl.t("resetSubtitle")}
      footer={backToSignIn}
    >
      <AuthError message={authErrorMessage(intl, reportedError)} />
      <form method="post" action="/handler/password-reset/submit">
        <HiddenReturnTo value={returnTo} />
        <input type="hidden" name="code" value={code ?? ""} />
        <TextField
          name="password"
          type="password"
          label={intl.t("newPasswordLabel")}
          autoComplete="new-password"
          autoFocus
        />
        <TextField
          name="password_confirmation"
          type="password"
          label={intl.t("confirmPasswordLabel")}
          autoComplete="new-password"
        />
        <PrimaryButton>{intl.t("resetSubmit")}</PrimaryButton>
      </form>
    </AuthCard>
  );
}

async function checkResetCode(
  config: NonNullable<ReturnType<typeof hexclaveClientConfig>>,
  code: string,
) {
  const result = await verifyPasswordResetCode(config, code);
  return result.ok ? null : authErrorKeyForCode(result.error.code, "invalidCode");
}

/** The API defines a reset code as exactly 45 URL-safe characters. */
function isResetCodeShaped(code: string): boolean {
  return /^[A-Za-z0-9_-]{45}$/u.test(code);
}
