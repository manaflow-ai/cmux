import { getTranslations } from "next-intl/server";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { isStackConfigured } from "@/app/lib/stack";
import { redirect } from "next/navigation";
import { Suspense } from "react";
import { DashboardAuthRecovery } from "../components/dashboard-auth-recovery";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { MobileDevicesDashboard } from "./mobile-devices-dashboard";

export const instant = true;

export default async function MobileDevicesDashboardPage({
  params,
}: { readonly params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");
  const t = await getTranslations({ locale, namespace: "dashboard.mobileDevices" });
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-5 border-b border-border pb-4">
        <h1 className="text-base font-medium">{t("title")}</h1>
        <p className="mt-1 text-sm text-muted">{t("description")}</p>
      </div>
      <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
        <MobileDevicesSection locale={locale} />
      </Suspense>
    </div>
  );
}

export async function MobileDevicesSection({ locale }: { readonly locale: string }) {
  const section = await loadDashboardSection(locale, "/dashboard/mobile-devices");
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath="/dashboard/mobile-devices" />;
  }
  return <MobileDevicesDashboard userId={section.user.id} />;
}
