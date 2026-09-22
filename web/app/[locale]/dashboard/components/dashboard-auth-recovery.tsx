import { getTranslations } from "next-intl/server";
import { dashboardAuthorizationSignInHref } from "@/app/lib/dashboard-auth";

/**
 * Shown in place of a private section when Stack cannot confirm the session.
 * The recovery link preserves the exact dashboard destination.
 */
export async function DashboardAuthRecovery({
  locale,
  returnPath,
}: {
  locale: string;
  returnPath: string;
}) {
  const t = await getTranslations({ locale, namespace: "authError" });
  return (
    <section
      data-testid="dashboard-auth-recovery"
      className="max-w-xl border border-border p-4"
    >
      <h1 className="text-sm font-medium">{t("genericTitle")}</h1>
      <p className="mt-2 text-sm text-muted">{t("genericBody")}</p>
      <a
        href={dashboardAuthorizationSignInHref(locale, returnPath)}
        className="mt-4 inline-block border border-border bg-foreground px-3 py-1.5 text-sm text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
      >
        {t("backToSignIn")}
      </a>
    </section>
  );
}
