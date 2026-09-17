import { Suspense } from "react";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { isStackConfigured } from "@/app/lib/stack";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { DashboardAuthRecovery } from "../../dashboard/components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../../dashboard/components/dashboard-skeleton";
import { CloudPortal } from "../../dashboard/cloud/cloud-portal";
import { resolveHomePortalPaths } from "../portal-routing";

export const instant = true;

type HomePortalProps = {
  params: Promise<{ locale: string; portal?: string[] }>;
};

export default function HomePortalPage(props: HomePortalProps) {
  return (
    <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
      <HomePortalSection {...props} />
    </Suspense>
  );
}

async function HomePortalSection({
  params,
}: HomePortalProps) {
  const { locale, portal } = await params;
  const { initialPath, returnPath } = resolveHomePortalPaths(portal);
  if (!isStackConfigured()) redirect("/");

  const section = await loadDashboardSection(locale, returnPath);
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath={returnPath} />;
  }
  const user = section.user;

  const t = await getTranslations({ locale, namespace: "dashboard.cloudPortal" });
  return (
    <CloudPortal
      displayName={user.displayName ?? user.primaryEmail ?? t("fallbackName")}
      initialPath={initialPath}
    />
  );
}
