import { getTranslations } from "next-intl/server";
import { loadDashboardSection } from "@/app/lib/dashboard-auth";
import { isStackConfigured } from "@/app/lib/stack";
import { redirect } from "next/navigation";
import { MobileDevicesDashboard } from "./mobile-devices-dashboard";

export const instant = true;

export default async function MobileDevicesDashboardPage({
  params,
}: { readonly params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");
  const t = await getTranslations({ locale, namespace: "dashboard.mobileDevices" });
  const section = await loadDashboardSection(locale, "/dashboard/mobile-devices");
  if (section.kind === "unavailable") {
    return <p className="mx-auto w-full max-w-5xl px-3 py-4 text-muted">{t("unavailable")}</p>;
  }
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <MobileDevicesDashboard userId={section.user.id} userEmail={section.user.primaryEmail ?? ""} />
    </div>
  );
}
