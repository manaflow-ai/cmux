"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { getRouteApi } from "@tanstack/react-router";
import { IsolatedErrorBoundary, SectionUnavailable } from "@/app/components/error-boundary";
import { teamBillingQuery } from "@/dashboard-app/queries/billing";
import { TeamBillingPanel } from "@/dashboard-app/screens/billing/team-billing-panel";

const teamBillingApi = getRouteApi("/shell/dashboard/teams/$teamId/billing");

/**
 * `/dashboard/teams/$teamId/billing`. The team layout already confirmed
 * membership; the billing view resolves access again, so a non-member still
 * sees only "not found". `?welcome=team` follows a Team checkout.
 */
export function TeamBillingTab() {
  const { teamId } = teamBillingApi.useParams();
  const { welcome } = teamBillingApi.useSearch();
  const { data: view } = useSuspenseQuery(teamBillingQuery(teamId));
  return (
    <IsolatedErrorBoundary name="dashboard-team-billing" fallback={<SectionUnavailable />}>
      <TeamBillingPanel view={view} welcome={welcome === "team"} />
    </IsolatedErrorBoundary>
  );
}
