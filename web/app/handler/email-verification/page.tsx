import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { connection } from "next/server";

import { cache } from "react";

import { verifyEmailCode } from "../../../services/auth/hexclave/auth";
import { hexclaveClientConfig } from "../../../services/auth/hexclave/config";
import { AuthCard } from "../components/auth-card";
import { firstParam } from "../components/auth-error-message";
import { authIntl } from "../components/auth-intl";

export const instant = false;

export async function generateMetadata(): Promise<Metadata> {
  const intl = await authIntl();
  // The title cannot describe the outcome: metadata is generated before the
  // code is redeemed, and redeeming it twice would burn a single-use link.
  return {
    title: intl.t("verifyPageTitle"),
    robots: { index: false, follow: false },
  };
}

/**
 * Confirms an emailed address.
 *
 * Stack renders this page on the client and calls `useUser()` while doing so,
 * which forced a Suspense boundary on the catch-all route to stop real
 * verification links returning HTTP 500. Verifying on the server removes the
 * boundary, the round trip, and the failure mode: the link either worked or it
 * did not, and the page says which.
 */
export default async function EmailVerificationPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  const config = hexclaveClientConfig();
  if (!config) notFound();

  const [params, intl] = await Promise.all([searchParams, authIntl()]);
  const code = firstParam(params.code);
  const verified = code ? await redeemOnce(config, code) : false;

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

/**
 * A verification code works exactly once, so a re-render inside the same
 * request must not spend it again. `cache` scopes the result to this request.
 */
const redeemOnce = cache(
  async (
    config: NonNullable<ReturnType<typeof hexclaveClientConfig>>,
    code: string,
  ): Promise<boolean> => (await verifyEmailCode(config, code)).ok,
);
