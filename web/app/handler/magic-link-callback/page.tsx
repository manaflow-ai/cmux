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
import { HiddenReturnTo, PrimaryButton } from "../components/auth-fields";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  return {
    title: intl.t("magicLinkTitle"),
    robots: { index: false, follow: false },
  };
}

/**
 * Asks the visitor to confirm before an emailed sign-in link is redeemed.
 *
 * The link is a single-use credential that arrives through a cross-site GET,
 * so redeeming it on page load would let a mail scanner or link preview spend
 * it before the person clicks, and would let any site start a session in
 * someone else's browser. The confirmation POST is same-origin and deliberate,
 * which closes both.
 */
export default async function MagicLinkCallbackPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  if (!hexclaveClientConfig()) notFound();

  const [params, intl] = await Promise.all([searchParams, authIntl()]);
  const rawReturnTo = firstParam(params.after_auth_return_to);
  const returnTo = rawReturnTo ? safeReturnToPath(rawReturnTo) : null;
  const code = firstParam(params.code);
  const errorKey = parseAuthErrorKey(firstParam(params.error));

  if (!code) {
    return (
      <AuthCard
        intl={intl}
        title={intl.t("verifyFailedTitle")}
        subtitle={intl.t("verifyFailedBody")}
        footer={
          <Link
            className="text-foreground underline decoration-link-underline underline-offset-2"
            href={authPageHref("/handler/sign-in", { returnTo })}
          >
            {intl.t("backToSignIn")}
          </Link>
        }
      >
        <span />
      </AuthCard>
    );
  }

  return (
    <AuthCard
      intl={intl}
      title={intl.t("magicLinkTitle")}
      subtitle={intl.t("magicLinkSubtitle")}
      footer={
        <Link
          className="text-foreground underline decoration-link-underline underline-offset-2"
          href={authPageHref("/handler/sign-in", { returnTo })}
        >
          {intl.t("backToSignIn")}
        </Link>
      }
    >
      <AuthError message={authErrorMessage(intl, errorKey)} />
      <form method="post" action="/handler/magic-link-callback/submit">
        <HiddenReturnTo value={returnTo} />
        <input type="hidden" name="code" value={code} />
        <PrimaryButton>{intl.t("magicLinkSubmit")}</PrimaryButton>
      </form>
    </AuthCard>
  );
}
