import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { parseAuthErrorKey } from "../../../services/auth/hexclave/errorCodes";
import { authPageHref, safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { AuthCard, AuthError } from "../components/auth-card";
import { authErrorMessage, firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";
import { HiddenReturnTo, PrimaryButton, TextField } from "../components/auth-fields";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  return { title: intl.t("otpTitle"), robots: { index: false, follow: false } };
}

export default async function OTPPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  if (!hexclaveClientConfig()) notFound();

  const [params, intl] = await Promise.all([searchParams, authIntl()]);
  const rawReturnTo = firstParam(params.after_auth_return_to);
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const email = firstParam(params.email) ?? "";
  const errorKey = parseAuthErrorKey(firstParam(params.error));

  return (
    <AuthCard
      intl={intl}
      title={intl.t("otpTitle")}
      subtitle={intl.t("otpSubtitle", { email })}
      footer={
        <Link
          className="text-foreground underline decoration-link-underline underline-offset-2"
          href={authPageHref("/handler/sign-in", { returnTo, email: email || null })}
        >
          {intl.t("backToSignIn")}
        </Link>
      }
    >
      <AuthError message={authErrorMessage(intl, errorKey)} />
      <form method="post" action="/handler/otp/submit">
        <HiddenReturnTo value={returnTo} />
        <input type="hidden" name="email" value={email} />
        <TextField
          name="code"
          type="text"
          label={intl.t("otpLabel")}
          autoComplete="one-time-code"
          autoFocus
          maxLength={6}
          pattern="[A-Za-z0-9]{6}"
        />
        <PrimaryButton>{intl.t("otpSubmit")}</PrimaryButton>
      </form>
      <form method="post" action="/handler/sign-in/submit" className="mt-3">
        <HiddenReturnTo value={returnTo} />
        <input type="hidden" name="email" value={email} />
        <input type="hidden" name="method" value="code" />
        <button
          type="submit"
          className="w-full text-center text-[13px] text-muted underline decoration-link-underline underline-offset-2 hover:text-foreground"
        >
          {intl.t("otpResend")}
        </button>
      </form>
    </AuthCard>
  );
}
