import { getTranslations } from "next-intl/server";
import { notFound, redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { ADMIN_EMAIL_DOMAINS, isAdminUser } from "@/services/admin/access";
import { loadProListSnapshot, type ProListSnapshot } from "@/services/admin/proList";

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
  // The Stripe-backed roster renders with the page; the client streams the
  // directory scans on mount. A database outage leaves the roster in an
  // error state with a retry, but never blocks the rest of the page.
  let initialSnapshot: ProListSnapshot | null = null;
  try {
    initialSnapshot = await loadProListSnapshot();
  } catch (error) {
    console.error("admin.pro_list.initial_load_failed", {
      failure: error instanceof Error ? error.name : "unknown",
    });
  }

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">
          {t("description", {
            domains: new Intl.ListFormat(locale, { type: "conjunction" }).format(
              ADMIN_EMAIL_DOMAINS,
            ),
          })}
        </p>
      </div>
      <AdminProPanel initialSnapshot={initialSnapshot} />
    </div>
  );
}
