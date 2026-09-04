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
  return { title: intl.t("forgotTitle"), robots: { index: false, follow: false } };
}

export default async function ForgotPasswordPage({
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
  const sent = firstParam(params.sent) === "1";

  const backToSignIn = (
    <Link
      className="text-foreground underline decoration-link-underline underline-offset-2"
      href={authPageHref("/handler/sign-in", {
        returnTo,
        email: email || null,
        method: "password",
      })}
    >
      {intl.t("backToSignIn")}
    </Link>
  );

  if (sent) {
    return (
      <AuthCard
        intl={intl}
        title={intl.t("forgotSentTitle")}
        subtitle={intl.t("forgotSentBody")}
        footer={backToSignIn}
      >
        <span />
      </AuthCard>
    );
  }

  return (
    <AuthCard
      intl={intl}
      title={intl.t("forgotTitle")}
      subtitle={intl.t("forgotSubtitle")}
      footer={backToSignIn}
    >
      <AuthError message={authErrorMessage(intl, errorKey)} />
      <form method="post" action="/handler/forgot-password/submit">
        <HiddenReturnTo value={returnTo} />
        <TextField
          name="email"
          type="email"
          label={intl.t("emailLabel")}
          placeholder={intl.t("emailPlaceholder")}
          autoComplete="email"
          defaultValue={email}
          autoFocus
        />
        <PrimaryButton>{intl.t("forgotSubmit")}</PrimaryButton>
      </form>
    </AuthCard>
  );
}
