import { getTranslations } from "next-intl/server";
import { Suspense } from "react";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { DashboardAuthRecovery } from "../../components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { NewTeamFlow } from "./new-team-flow";

const RETURN_PATH = "/dashboard/teams/new";

export const instant = true;

export default async function NewTeamPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.teams.new" });
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <Suspense fallback={<DashboardSectionSkeleton variant="cards" />}>
        <NewTeamSection locale={locale} />
      </Suspense>
    </div>
  );
}

async function NewTeamSection({ locale }: { locale: string }) {
  const section = await loadDashboardSection(locale, RETURN_PATH);
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath={RETURN_PATH} />;
  }
  return (
    <IsolatedErrorBoundary name="dashboard-team-create" fallback={<SectionUnavailable />}>
      <NewTeamFlow />
    </IsolatedErrorBoundary>
  );
}
