import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { DashboardShell } from "./dashboard-shell";

export default async function DashboardLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!isStackConfigured()) {
    redirect("/");
  }

  const stackServerApp = getStackServerApp();
  const user = await stackServerApp.getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/vault/sessions")));
  }

  return (
    <Suspense>
      <StackProvider app={stackServerApp}>
        <StackTheme>
          <DashboardShell>{children}</DashboardShell>
        </StackTheme>
      </StackProvider>
    </Suspense>
  );
}
