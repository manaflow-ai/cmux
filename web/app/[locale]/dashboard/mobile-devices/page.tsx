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
    <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:px-6 sm:py-8">
      <div className="mb-7 flex items-start gap-4 border-b border-border pb-6">
        <span className="mt-0.5 flex size-10 shrink-0 items-center justify-center border border-border bg-code-bg text-muted" aria-hidden="true">
          <MobileDevicesIcon />
        </span>
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.16em] text-muted">{t("eyebrow")}</p>
          <h1 className="mt-1 text-xl font-medium tracking-tight">{t("title")}</h1>
          <p className="mt-2 max-w-2xl text-sm leading-6 text-muted">{t("description")}</p>
        </div>
      </div>
      <Suspense fallback={<DashboardSectionSkeleton variant="rows" />}>
        <MobileDevicesSection locale={locale} />
      </Suspense>
    </div>
  );
}

function MobileDevicesIcon() {
  return <svg aria-hidden="true" viewBox="0 0 20 20" className="size-5" fill="none" stroke="currentColor" strokeWidth="1.2"><rect x="2.5" y="3" width="11" height="8" rx="1" /><path d="M5.5 14.5h5M8 11v3.5M15 6.5h2.5v10H10v-2" /></svg>;
}

export async function MobileDevicesSection({ locale }: { readonly locale: string }) {
  const section = await loadDashboardSection(locale, "/dashboard/mobile-devices");
  if (section.kind === "unavailable") {
    return <DashboardAuthRecovery locale={locale} returnPath="/dashboard/mobile-devices" />;
  }
  return <MobileDevicesDashboard userId={section.user.id} />;
}
