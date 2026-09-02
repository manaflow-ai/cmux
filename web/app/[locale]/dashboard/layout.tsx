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
            {/* This shared-layout boundary covers a cold dashboard entry. It is
                above the work that reruns between sibling tabs, and the route
                has no loading.tsx, so navigation keeps the current tab visible. */}
            <DashboardShell vaultEnabled={isVaultEnabled()}>
              {children}
            </DashboardShell>
          </DashboardQueryProvider>
        </StackTheme>
      </StackProvider>
    </Suspense>
  );
}
