import { getTranslations } from "next-intl/server";
import { notFound, redirect } from "next/navigation";
import { Suspense } from "react";

import { getRequestScopedStackUser, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { ADMIN_EMAIL_DOMAINS, isAdminUser } from "@/services/admin/access";
import { withPrioritySpan } from "@/services/telemetry";

import { AdminProPanel } from "./admin-pro-panel";
import { AdminProRoster } from "./admin-pro-roster";

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
  const user = await withPrioritySpan(
    "cmux-admin-dashboard",
    "cmux.admin.auth",
    { "http.route": "/dashboard/admin", "cmux.locale": locale },
    () => getRequestScopedStackUser("admin_page"),
  );
  if (!user || user.isAnonymous) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/admin")));
  }
  // Non-admins get the same 404 as a route that does not exist.
  if (!isAdminUser(user)) {
    notFound();
  }

  const t = await getTranslations({ locale, namespace: "dashboard.admin" });
  // The roster streams in behind a Suspense boundary so a slow database read
  // never holds the search panel; the client then streams the directory scans.
  const roster = (
    <Suspense fallback={<RosterFallback title={t("list.title")} loading={t("list.loading")} />}>
      <AdminProRoster />
    </Suspense>
  );

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
      <AdminProPanel roster={roster} />
    </div>
  );
}

function RosterFallback({ title, loading }: { title: string; loading: string }) {
  return (
    <section className="border border-border p-3" aria-busy="true">
      <h2 className="text-sm font-medium">{title}</h2>
      <p className="mt-1 text-muted">{loading}</p>
    </section>
  );
}
