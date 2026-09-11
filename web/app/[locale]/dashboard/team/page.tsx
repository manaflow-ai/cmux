import { AccountSettings } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { isStackConfigured } from "@/app/lib/stack";
import { DashboardAuthRecovery } from "../components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";

const RETURN_PATH = "/dashboard/team";

export const instant = true;

export default async function DashboardTeamPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) {
    redirect(`/${locale}`);
  }

  return (
    <div className="w-full px-3 py-4">
      <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
        <TeamSettingsSection locale={locale} />
      </Suspense>
    </div>
  );
}

async function TeamSettingsSection({ locale }: { locale: string }) {
  const section = await loadDashboardSection(locale, RETURN_PATH);
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath={RETURN_PATH} />;
  }
  return <AccountSettings />;
}
