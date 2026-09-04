import { StackProvider, StackTheme } from "@stackframe/stack";
import { getTranslations } from "next-intl/server";
import {
  DashboardAuthorizationUnavailableError,
  dashboardAuthorizationSignInHref,
  dashboardReturnPath,
  requireDashboardUser,
} from "@/app/lib/dashboard-auth";
import { getStackServerApp } from "@/app/lib/stack";
import { isVaultEnabled } from "@/services/vault/config";
import { DashboardQueryProvider } from "./components/query-provider";
import { DashboardShell } from "./dashboard-shell";

// A cold entry must finish the server session check before any dashboard UI.
// Sibling pages below this layout can still use instant navigation.
export const instant = false;

export default async function DashboardLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const returnPath = await dashboardReturnPath();
  try {
    await requireDashboardUser(locale, returnPath);
  } catch (error) {
    if (!(error instanceof DashboardAuthorizationUnavailableError)) {
      throw error;
    }
    // Keep the private shell out of the response when Stack is unavailable.
    // The recovery link preserves the exact dashboard destination.
    const t = await getTranslations({ locale, namespace: "authError" });
    return (
      <main className="mx-auto w-full max-w-5xl px-3 py-8">
        <section className="max-w-xl border border-border p-4">
          <h1 className="text-sm font-medium">{t("genericTitle")}</h1>
          <p className="mt-2 text-sm text-muted">{t("genericBody")}</p>
          <a
            href={dashboardAuthorizationSignInHref(locale, returnPath)}
            className="mt-4 inline-block border border-border bg-foreground px-3 py-1.5 text-sm text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {t("backToSignIn")}
          </a>
        </section>
      </main>
    );
  }

  return (
    <StackProvider app={getStackServerApp()}>
      <StackTheme>
        <DashboardQueryProvider>
          <DashboardShell vaultEnabled={isVaultEnabled()}>
            {children}
          </DashboardShell>
        </DashboardQueryProvider>
      </StackTheme>
    </StackProvider>
  );
}
