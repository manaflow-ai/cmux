import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { DashboardSkeleton } from "./components/dashboard-skeleton";
import { DashboardQueryProvider } from "./components/query-provider";
import { DashboardShell } from "./dashboard-shell";

// Auth redirects are owned by each page, not this layout: a layout cannot see
// the requested URL, so redirecting here would send unauthenticated visitors
// to a fixed return path and drop page-specific query params (e.g. the
// ?code=... on /dashboard/vault/cli-auth). Every page under /dashboard must
// check getUser() itself and build its own sign-in return path.
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
    <StackProvider app={getStackServerApp()}>
      <StackTheme>
        <DashboardQueryProvider>
          <DashboardShell>
            <Suspense fallback={<DashboardSkeleton />}>{children}</Suspense>
          </DashboardShell>
        </DashboardQueryProvider>
      </StackTheme>
    </StackProvider>
  );
}
