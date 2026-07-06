import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { buildAlternates } from "@/i18n/seo";
import { SiteHeader } from "../../components/site-header";
import {
  SubrouterAccountManager,
  type StackUserLike,
} from "../components/subrouter-account-manager";

export const dynamic = "force-dynamic";

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ team?: string | string[] }>;
};

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/dashboard/ai-accounts"),
  };
}

export default async function AiAccountsPage({ params, searchParams }: PageProps) {
  const { locale } = await params;
  const { team: teamParam } = await searchParams;
  const t = await getTranslations({ locale, namespace: "dashboard.aiAccounts" });
  const stackUser = await getStackServerApp().getUser({ or: "return-null" }) as StackUserLike | null;
  if (!stackUser) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/ai-accounts")));
  }

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <SubrouterAccountManager
        locale={locale}
        stackUser={stackUser}
        teamParam={teamParam}
        teamPath="/dashboard/ai-accounts"
        title={t("title")}
        description={t("description")}
        className="mx-auto w-full max-w-6xl px-6 py-10"
      />
    </div>
  );
}
