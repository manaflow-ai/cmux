"use client";

import { useLocale, useTranslations } from "next-intl";
import { signInHref } from "../lib/session";

/**
 * Shown in place of the dashboard when Stack cannot confirm the session.
 * The recovery link preserves the exact dashboard destination.
 */
export function DashboardAuthRecovery({ returnPath }: { readonly returnPath: string }) {
  const t = useTranslations("authError");
  const locale = useLocale();
  return (
    <section
      data-testid="dashboard-auth-recovery"
      className="m-3 max-w-xl border border-border p-4"
    >
      <h1 className="text-sm font-medium">{t("genericTitle")}</h1>
      <p className="mt-2 text-sm text-muted">{t("genericBody")}</p>
      <a
        href={signInHref(locale, returnPath)}
        className="mt-4 inline-block border border-border bg-foreground px-3 py-1.5 text-sm text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
      >
        {t("backToSignIn")}
      </a>
    </section>
  );
}

/**
 * Sends a signed-out visitor to sign-in. The navigation starts from a
 * callback ref so it runs once on mount without an effect.
 */
export function SignInRedirect({ returnPath }: { readonly returnPath: string }) {
  const locale = useLocale();
  const href = signInHref(locale, returnPath);
  return (
    <span
      hidden
      ref={(node) => {
        if (node) window.location.replace(href);
      }}
    />
  );
}
