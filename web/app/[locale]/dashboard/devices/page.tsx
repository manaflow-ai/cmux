// Account device dashboard — the device list as the authorization surface.
// Every signed-in cmux device (Macs and iPhones) with its lifecycle status,
// version + release track, per-device sync state against the account list
// revision, and the revoke / restore / remove controls. Linked from the Mac
// app's Settings.

import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { loadDeviceDashboard } from "@/services/devices/dashboard";
import { DevicesView } from "./devices-view";

type PageProps = {
  params: Promise<{ locale: string }>;
};

export async function generateMetadata({ params }: PageProps) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.devices" });
  const alternates = buildAlternates(locale, "/dashboard/devices");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function DashboardDevicesPage({ params }: PageProps) {
  const { locale } = await params;
  if (!isStackConfigured()) {
    redirect(`/${locale}`);
  }
  const app = getStackServerApp();
  const user = await app.getUser({ or: "return-null" });
  if (!user || user.isAnonymous) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/devices")));
  }
  const authJson = await app.getAuthJson();
  const data = await loadDeviceDashboard(user.id, authJson?.accessToken ?? null);

  return (
    <DevicesView
      initialData={data}
      initialNowIso={new Date().toISOString()}
    />
  );
}
