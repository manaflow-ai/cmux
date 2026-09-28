import { Suspense } from "react";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { DashboardAuthRecovery } from "../../components/dashboard-auth-recovery";
import { DashboardSkeleton } from "../../components/dashboard-skeleton";
import { TeamShell } from "./team-shell";

export const instant = true;

export default function TeamLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string; teamId: string }>;
}) {
  return (
    <Suspense fallback={<DashboardSkeleton variant="rows" />}>
      <TeamSection params={params}>{children}</TeamSection>
    </Suspense>
  );
}

async function TeamSection({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string; teamId: string }>;
}) {
  const { locale, teamId } = await params;
  const returnPath = `/dashboard/teams/${encodeURIComponent(teamId)}`;
  const section = await loadDashboardSection(locale, returnPath);
  if (section.kind === "unavailable") {
    return (
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        <DashboardAuthRecovery locale={locale} returnPath={returnPath} />
      </div>
    );
  }
  return (
    <IsolatedErrorBoundary name="dashboard-team" fallback={<SectionUnavailable />}>
      <TeamShell teamId={teamId}>{children}</TeamShell>
    </IsolatedErrorBoundary>
  );
}
