import { getTranslations } from "next-intl/server";
import { notFound, redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { ADMIN_EMAIL_DOMAINS, isAdminUser } from "@/services/admin/access";

import { AdminProPanel } from "./admin-pro-panel";

// Admin membership is a request-fresh check on the signed-in user.
export const instant = false;

export default async function DashboardAdminPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user || user.isAnonymous) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/admin")));
  }
  // Non-admins get the same 404 as a route that does not exist.
  if (!isAdminUser(user)) {
    notFound();
  }

  const t = await getTranslations({ locale, namespace: "dashboard.admin" });

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">
          {t("description", { domains: ADMIN_EMAIL_DOMAINS.join(", ") })}
        </p>
      </div>
      <AdminProPanel />
    </div>
  );
}
