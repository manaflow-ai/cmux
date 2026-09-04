import type { Metadata } from "next";
import Link from "next/link";
import { headers } from "next/headers";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { parseAuthErrorKey } from "../../../services/auth/hexclave/errorCodes";
import { authPageHref, safeReturnToPath } from "../../../services/auth/hexclave/returnTo";
import { AuthCard, AuthDivider, AuthError } from "../components/auth-card";
import { authErrorMessage, firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";
import {
  HiddenReturnTo,
  PrimaryButton,
  TextField,
} from "../components/auth-fields";
import { isCoderouterHost } from "../components/auth-host";
import { OAuthButtons } from "../components/oauth-buttons";
import { PasskeySignIn } from "../components/passkey-sign-in";

export const instant = false;

type SignInPageProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  return {
    title: intl.t("signInTitle"),
    robots: { index: false, follow: false },
  };
}

export default async function SignInPage({ searchParams }: SignInPageProps) {
  // The page reads one-time query parameters, so it must never be prerendered.
  await connection();
  if (!hexclaveClientConfig()) notFound();

  const [params, intl, requestHeaders] = await Promise.all([
    searchParams,
    authIntl(),
    headers(),
  ]);
  const emailOnly = isCoderouterHost(requestHeaders.get("host"));
  const returnTo = firstParam(params.after_auth_return_to);
  const safeReturnTo = returnTo ? safeReturnToPath(returnTo) : null;
  const email = firstParam(params.email) ?? "";
  const errorKey = parseAuthErrorKey(firstParam(params.error));
  // coderouter never offers a password, so a hand-written query parameter
  // cannot summon the field there.
  const usePassword = !emailOnly && firstParam(params.method) === "password";

  return (
    <AuthCard
      intl={intl}
      title={intl.t("signInTitle")}
      subtitle={intl.t("signInSubtitle")}
      footer={
        <p>
          {intl.t("noAccount")}{" "}
          <Link
            className="text-foreground underline decoration-link-underline underline-offset-2"
            href={authPageHref("/handler/sign-up", { returnTo: safeReturnTo })}
          >
            {intl.t("noAccountLink")}
          </Link>
        </p>
      }
    >
      <AuthError message={authErrorMessage(intl, errorKey)} />
      {emailOnly ? null : (
        <>
          <OAuthButtons intl={intl} returnTo={safeReturnTo} />
          <AuthDivider label={intl.t("dividerOr")} />
        </>
      )}

      <form method="post" action="/handler/sign-in/submit">
        <HiddenReturnTo value={safeReturnTo} />
        <TextField
          name="email"
          type="email"
          label={intl.t("emailLabel")}
          placeholder={intl.t("emailPlaceholder")}
          autoComplete="email"
          defaultValue={email}
          autoFocus={!email}
        />
        {usePassword ? (
          <TextField
            name="password"
            type="password"
            label={intl.t("passwordLabel")}
            autoComplete="current-password"
            autoFocus={Boolean(email)}
            hint={
              <Link
                className="text-[12px] font-normal text-muted underline decoration-link-underline underline-offset-2"
                href={authPageHref("/handler/forgot-password", {
                  returnTo: safeReturnTo,
                  email: email || null,
                })}
              >
                {intl.t("forgotPassword")}
              </Link>
            }
          />
        ) : null}
        <input type="hidden" name="method" value={usePassword ? "password" : "code"} />
        <PrimaryButton>
          {usePassword ? intl.t("signInSubmit") : intl.t("emailCodeSubmit")}
        </PrimaryButton>
      </form>

      {emailOnly ? null : (
        <div className="mt-3 flex flex-col gap-2">
          <Link
            className="flex min-h-10 w-full items-center justify-center border border-border px-4 text-sm font-medium text-foreground no-underline hover:bg-code-bg"
            href={authPageHref("/handler/sign-in", {
              returnTo: safeReturnTo,
              email: email || null,
              method: usePassword ? null : "password",
            })}
          >
            {usePassword ? intl.t("useEmailCode") : intl.t("usePassword")}
          </Link>
          <PasskeySignIn
            intl={{
              label: intl.t("passkeySubmit"),
              working: intl.t("passkeyWorking"),
              unsupported: intl.t("passkeyUnsupported"),
            }}
            returnTo={safeReturnTo}
          />
        </div>
      )}
    </AuthCard>
  );
}
