import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { isVaultEnabled } from "@/services/vault/config";
import { DashboardSkeleton } from "./components/dashboard-skeleton";
import { DashboardQueryProvider } from "./components/query-provider";
import { DashboardShell } from "./dashboard-shell";

export const instant = true;

// Auth redirects are owned by each page, not this layout: a layout cannot see
// the requested URL, so redirecting here would send unauthenticated visitors
// to a fixed return path and drop page-specific query params. Every page under
// /dashboard must check getUser() itself and build its own sign-in return path.
export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  if (!isStackConfigured()) {
    redirect("/");
  }

  return (
    <Suspense fallback={<DashboardSkeleton />}>
      <StackProvider app={getStackServerApp()}>
        <StackTheme>
          <DashboardQueryProvider>
            {/* Keep the current tab mounted while fresh page data resolves.
                A nested full-page Suspense fallback makes rapid tab switches
                flash the dashboard skeleton. The dashboard loading boundary
                above still covers first entry into the dashboard. */}
            <DashboardShell vaultEnabled={isVaultEnabled()}>
              {children}
            </DashboardShell>
          </DashboardQueryProvider>
        </StackTheme>
      </StackProvider>
    </Suspense>
  );
}
