import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { CloudPortal } from "../../dashboard/cloud/cloud-portal";
import { canEnterCloudPortal, resolveHomePortalPaths } from "../portal-routing";

export const dynamic = "force-dynamic";

export default async function HomePortalPage({
  params,
}: {
  params: Promise<{ locale: string; portal?: string[] }>;
}) {
  const { locale, portal } = await params;
  const { initialPath, returnPath } = resolveHomePortalPaths(portal);
  if (!isStackConfigured()) redirect("/");

  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!canEnterCloudPortal(user)) {
    redirect(vaultSignInHref(localizedVaultPath(locale, returnPath)));
  }

  const t = await getTranslations({ locale, namespace: "dashboard.cloud" });
  return (
    <CloudPortal
      displayName={user.displayName ?? user.primaryEmail ?? t("fallbackName")}
      initialPath={initialPath}
    />
  );
}
