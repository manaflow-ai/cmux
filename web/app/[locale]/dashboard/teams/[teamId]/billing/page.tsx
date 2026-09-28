import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { dashboardAuthorizationSignInHref } from "@/app/lib/dashboard-auth";
import { getStackServerApp } from "@/app/lib/stack";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { loadTeamBillingView } from "@/services/billing/teamBillingView";
import { TeamBillingPanel } from "../../../billing/team-billing-panel";
import { DashboardSectionSkeleton } from "../../../components/dashboard-skeleton";

export const instant = true;

type Params = Promise<{ locale: string; teamId: string }>;
type SearchParams = Promise<{ welcome?: string | string[] }>;

export default function TeamBillingPage({
  params,
  searchParams,
}: {
  params: Params;
  searchParams: SearchParams;
}) {
  return (
    <Suspense fallback={<DashboardSectionSkeleton variant="cards" />}>
      <TeamBillingSection params={params} searchParams={searchParams} />
    </Suspense>
  );
}

/**
 * The layout already confirmed the session and membership. The billing view
 * re-resolves access itself, so a non-member still sees only "not found".
 */
async function TeamBillingSection({ params, searchParams }: { params: Params; searchParams: SearchParams }) {
  const [{ locale, teamId }, query] = await Promise.all([params, searchParams]);
  const returnPath = `/dashboard/teams/${encodeURIComponent(teamId)}/billing`;
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) redirect(dashboardAuthorizationSignInHref(locale, returnPath));
  const [t, view] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.billing" }),
    loadTeamBillingView(user, teamId),
  ]);
  const welcome = (Array.isArray(query.welcome) ? query.welcome[0] : query.welcome) === "team";
  return (
    <IsolatedErrorBoundary name="dashboard-team-billing" fallback={<SectionUnavailable />}>
      <TeamBillingPanel view={view} locale={locale} t={t} welcome={welcome} />
    </IsolatedErrorBoundary>
  );
}
