import type { Metadata } from "next";
import { cookies } from "next/headers";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { parseAuthErrorKey } from "../../../services/auth/hexclave/errorCodes";
import { readResetCodeCookie } from "../../../services/auth/hexclave/resetCode";
import { authPageHref, safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { AuthCard, AuthError } from "../components/auth-card";
import { authErrorMessage, firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";
import { HiddenReturnTo, PrimaryButton, TextField } from "../components/auth-fields";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  // Neutral on purpose: this route also renders the expired-link and finished
  // states, and metadata is produced before either is known.
  return { title: intl.t("forgotTitle"), robots: { index: false, follow: false } };
}

/**
 * Chooses the new password. Reached only from `/handler/password-reset`, which
 * has already checked the emailed code and parked it in an httpOnly cookie, so
 * nothing on this page or in its address is a credential.
 */
export default async function NewPasswordPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  if (!hexclaveClientConfig()) notFound();

  const [params, intl, cookieStore] = await Promise.all([
    searchParams,
    authIntl(),
    cookies(),
  ]);
  const rawReturnTo = firstParam(params.after_auth_return_to);
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const reportedError = parseAuthErrorKey(firstParam(params.error));
  const done = firstParam(params.done) === "1";
  const hasCode = Boolean(readResetCodeCookie(cookieStore));

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

  if (!hasCode) {
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
      <form method="post" action="/handler/new-password/submit">
        <HiddenReturnTo value={returnTo} />
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
