import { StackProvider } from "@hexclave/next";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { optionalDashboardUser } from "@/app/lib/dashboard-auth";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { DashboardQueryProvider } from "@/dashboard-app/components/query-provider";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { JoinInvite } from "./join-invite";

type Params = Promise<{ locale: string; token: string }>;

export const instant = true;

export default function JoinTeamPage({ params }: { params: Params }) {
  return (
    <main className="min-h-screen bg-background px-3 py-16 text-sm text-foreground">
      <Suspense fallback={<DashboardSectionSkeleton variant="cards" />}>
        <JoinSection params={params} />
      </Suspense>
    </main>
  );
}

/** Invite links are shared outside the dashboard, so this page signs visitors in itself. */
async function JoinSection({ params }: { params: Params }) {
  const { locale, token } = await params;
  if (!isStackConfigured()) redirect(`/${locale}`);
  const user = await optionalDashboardUser();
  if (!user) redirect(vaultSignInHref(localizedVaultPath(locale, `/join/${encodeURIComponent(token)}`)));
  return (
    <StackProvider app={getStackServerApp()}>
      <DashboardQueryProvider>
        <JoinInvite token={token} viewerEmail={user.primaryEmail} />
      </DashboardQueryProvider>
    </StackProvider>
  );
}
