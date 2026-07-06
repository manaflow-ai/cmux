import { Suspense } from "react";
import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
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
    <Suspense>
      <StackProvider app={getStackServerApp()}>
        <StackTheme>
          <DashboardShell>{children}</DashboardShell>
        </StackTheme>
      </StackProvider>
    </Suspense>
  );
}
