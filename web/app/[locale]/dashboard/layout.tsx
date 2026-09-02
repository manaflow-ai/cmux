import { StackProvider, StackTheme } from "@stackframe/stack";
import { requireDashboardUser } from "@/app/lib/dashboard-auth";
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
  await requireDashboardUser(locale);

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
