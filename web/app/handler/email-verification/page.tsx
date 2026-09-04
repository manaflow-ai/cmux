import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { AuthCard } from "../components/auth-card";
import { firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";
import { PrimaryButton } from "../components/auth-fields";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  return {
    title: intl.t("verifyPageTitle"),
    robots: { index: false, follow: false },
  };
}

/**
 * Confirms an emailed address.
 *
 * The code works once, and mail scanners and link previews fetch the URL
 * before the person does, so the GET only asks. `submit` spends the code.
 *
 * Stack renders this page on the client and calls `useUser()` while doing so,
 * which forced a Suspense boundary on the catch-all route to stop real
 * verification links returning HTTP 500. Rendering it on the server removes
 * the boundary, the round trip, and the failure mode.
 */
export default async function EmailVerificationPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  if (!hexclaveClientConfig()) notFound();

  const [params, intl] = await Promise.all([searchParams, authIntl()]);
  const code = firstParam(params.code);
  const outcome = firstParam(params.verified);

  if (outcome === "1" || outcome === "0" || !code) {
    const verified = outcome === "1";
    return (
      <AuthCard
        intl={intl}
        title={verified ? intl.t("verifyDoneTitle") : intl.t("verifyFailedTitle")}
        subtitle={verified ? intl.t("verifyDoneBody") : intl.t("verifyFailedBody")}
      >
        <Link
          className="flex min-h-10 w-full items-center justify-center bg-foreground px-4 text-sm font-medium text-background no-underline hover:opacity-85"
          href={verified ? "/dashboard" : "/handler/sign-in"}
        >
          {verified ? intl.t("continueLink") : intl.t("backToSignIn")}
        </Link>
      </AuthCard>
    );
  }

  return (
    <AuthCard
      intl={intl}
      title={intl.t("verifyConfirmTitle")}
      subtitle={intl.t("verifyConfirmSubtitle")}
    >
      <form method="post" action="/handler/email-verification/submit">
        <input type="hidden" name="code" value={code} />
        <PrimaryButton>{intl.t("verifyConfirmSubmit")}</PrimaryButton>
      </form>
    </AuthCard>
  );
}
