import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  SubrouterAccountManager,
  type StackUserLike,
} from "../components/subrouter-account-manager";

export const dynamic = "force-dynamic";

export default async function SubrouterOverviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
}) {
  const { locale } = await params;
  const { team: teamParam } = await searchParams;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" }) as StackUserLike | null;
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/subrouter")));
  }

  const t = await getTranslations({ locale, namespace: "dashboard.subrouter" });

  return (
    <SubrouterAccountManager
      locale={locale}
      stackUser={user}
      teamParam={teamParam}
      teamPath="/dashboard/subrouter"
      title={t("title")}
      description={t("description")}
      className="mx-auto w-full max-w-6xl px-6 py-10"
    />
  );
}
