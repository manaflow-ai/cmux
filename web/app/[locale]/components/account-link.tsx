"use client";

import { useUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { Suspense } from "react";
import { Link } from "../../../i18n/navigation";
import { IsolatedErrorBoundary } from "../../components/error-boundary";
import { stackClientApp } from "../../lib/stack-client";

/**
 * Billing shows the visitor's plan and the price they actually pay. A
 * signed-out visitor goes through sign-in and lands back on it.
 */
const ACCOUNT_HREF = "/dashboard/billing";

function SignedInAwareLink({ className, onClick }: AccountLinkProps) {
  const t = useTranslations("nav");
  const user = useUser({ or: "return-null" });
  return (
    <Link href={ACCOUNT_HREF} onClick={onClick} className={className}>
      {user ? t("account") : t("signIn")}
    </Link>
  );
}

function SignInLink({ className, onClick }: AccountLinkProps) {
  const t = useTranslations("nav");
  return (
    <Link href={ACCOUNT_HREF} onClick={onClick} className={className}>
      {t("signIn")}
    </Link>
  );
}

type AccountLinkProps = { className?: string; onClick?: () => void };

/**
 * "Account" for a signed-in visitor, otherwise "Sign in"; both open billing.
 * Without a Hexclave client (no provider is mounted) there is no session to
 * read. `useUser` also throws during an outage, so the link falls back to
 * "Sign in" on its own instead of unmounting the header.
 */
export function AccountLink(props: AccountLinkProps) {
  const fallback = <SignInLink {...props} />;
  if (!stackClientApp) return fallback;
  return (
    <IsolatedErrorBoundary name="site-header-account-link" fallback={fallback}>
      <Suspense fallback={fallback}>
        <SignedInAwareLink {...props} />
      </Suspense>
    </IsolatedErrorBoundary>
  );
}
