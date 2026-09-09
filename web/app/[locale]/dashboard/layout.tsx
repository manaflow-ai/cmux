import { StackProvider, StackTheme } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import {
  DashboardAuthorizationUnavailableError,
  dashboardReturnPath,
  optionalDashboardUser,
  requireDashboardUser,
} from "@/app/lib/dashboard-auth";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { isVaultEnabled } from "@/services/vault/config";
import { DashboardQueryProvider } from "./components/query-provider";
import {
  DashboardAccountMenu,
  DashboardAccountMenuFallback,
} from "./dashboard-account-menu";
import { DashboardShell } from "./dashboard-shell";

// The shell is static. Every session read sits behind its own Suspense
// boundary, so navigations into and between dashboard pages paint the
// sidebar and page frames from the prefetched app shell.
export const instant = true;

export default async function DashboardLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");

  return (
    <StackProvider app={getStackServerApp()}>
      <StackTheme>
        <DashboardQueryProvider>
          <DashboardShell
            vaultEnabled={isVaultEnabled()}
            account={
              <Suspense fallback={<DashboardAccountMenuFallback />}>
                <DashboardAccountSlot />
              </Suspense>
            }
          >
            <Suspense fallback={null}>
              <DashboardSessionGuard locale={locale} />
            </Suspense>
            {children}
          </DashboardShell>
        </DashboardQueryProvider>
      </StackTheme>
    </StackProvider>
  );
}

// Streams the identity row once the session resolves; signed-out visitors
// get the sign-in control while the middleware redirect completes. Every
// other server read in this render shares the same cached session.
async function DashboardAccountSlot() {
  const user = await optionalDashboardUser();
  return <DashboardAccountMenu user={user} />;
}

// Middleware already turns away requests with no session cookie. This covers
// a cookie whose session Stack rejects, for pages with no private section of
// their own, without holding the page content behind the check.
async function DashboardSessionGuard({ locale }: { locale: string }) {
  try {
    await requireDashboardUser(locale, await dashboardReturnPath());
  } catch (error) {
    // An outage is reported inside each private section. Redirects and
    // unknown failures still propagate.
    if (!(error instanceof DashboardAuthorizationUnavailableError)) throw error;
  }
  return null;
}
