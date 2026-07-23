import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { CloudPortal } from "../../dashboard/cloud/cloud-portal";

export const dynamic = "force-dynamic";

export default async function HomePortalPage({
  params,
}: {
  params: Promise<{ locale: string; portal?: string[] }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) redirect("/");

  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user || user.isAnonymous) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/home")));
  }

  const t = await getTranslations({ locale, namespace: "dashboard.cloud" });
  return (
    <CloudPortal
      displayName={user.displayName ?? user.primaryEmail ?? t("fallbackName")}
    />
  );
}
