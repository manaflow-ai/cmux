import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { parseAuthErrorKey } from "../../../services/auth/hexclave/errorCodes";
import { authPageHref, safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { AuthCard, AuthDivider, AuthError } from "../components/auth-card";
import { authErrorMessage, firstParam } from "../components/auth-error-message";
import { authIntl, richText } from "../components/auth-intl";
import { HiddenReturnTo, PrimaryButton, TextField } from "../components/auth-fields";
import { OAuthButtons } from "../components/oauth-buttons";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  return { title: intl.t("signUpTitle"), robots: { index: false, follow: false } };
}

export default async function SignUpPage({
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
      title={intl.t("signUpTitle")}
      subtitle={intl.t("signUpSubtitle")}
      footer={
        <>
          <p>
            {intl.t("haveAccount")}{" "}
            <Link
              className="text-foreground underline decoration-link-underline underline-offset-2"
              href={authPageHref("/handler/sign-in", { returnTo, email: email || null })}
            >
              {intl.t("haveAccountLink")}
            </Link>
          </p>
          <p className="mt-3 text-[12px] leading-5">
            {richText(
              intl.t("termsNotice"),
              {
                terms: (
                  <Link
                    className="underline decoration-link-underline underline-offset-2"
                    href="/terms-of-service"
                  >
                    {intl.t("termsLink")}
                  </Link>
                ),
                privacy: (
                  <Link
                    className="underline decoration-link-underline underline-offset-2"
                    href="/privacy-policy"
                  >
                    {intl.t("privacyLink")}
                  </Link>
                ),
              },
            )}
          </p>
        </>
      }
    >
      <AuthError message={authErrorMessage(intl, errorKey)} />
      <OAuthButtons intl={intl} returnTo={returnTo} />
      <AuthDivider label={intl.t("dividerOr")} />
      <form method="post" action="/handler/sign-up/submit">
        <HiddenReturnTo value={returnTo} />
        <TextField
          name="email"
          type="email"
          label={intl.t("emailLabel")}
          placeholder={intl.t("emailPlaceholder")}
          autoComplete="email"
          defaultValue={email}
          autoFocus={!email}
        />
        <TextField
          name="password"
          type="password"
          label={intl.t("passwordLabel")}
          autoComplete="new-password"
        />
        <PrimaryButton>{intl.t("signUpSubmit")}</PrimaryButton>
      </form>
    </AuthCard>
  );
}
