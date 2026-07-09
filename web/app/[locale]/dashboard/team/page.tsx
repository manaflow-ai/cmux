import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { loadTeamSummary, type StackTeamUserLike } from "@/services/team/invites";
import { CreateTeamForm } from "./create-team-form";
import { TeamManagerClient } from "./team-client";

export const dynamic = "force-dynamic";

export default async function DashboardTeamPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<{ joined?: string | string[] }>;
}) {
  const [{ locale }, query] = await Promise.all([
    params,
    searchParams ?? Promise.resolve({} as { joined?: string | string[] }),
  ]);
  if (!isStackConfigured()) redirect("/");
  const user = await getStackServerApp().getUser({ or: "return-null" }) as StackTeamUserLike | null;
  if (!user) redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/team")));
  const t = await getTranslations({ locale, namespace: "dashboard.team" });
  let summary = null;
  try {
    summary = await loadTeamSummary(user);
  } catch {
    summary = null;
  }
  const joined = (Array.isArray(query.joined) ? query.joined[0] : query.joined) === "1";

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {summary ? (
        <TeamManagerClient
          initialSummary={summary}
          currentUserId={user.id}
          locale={locale}
          joined={joined}
        />
      ) : (
        <CreateTeamForm />
      )}
    </div>
  );
}
