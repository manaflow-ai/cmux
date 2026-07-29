import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { ApproveForm } from "./approve-form";

export const dynamic = "force-dynamic";

export default async function VaultCliAuthPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ code?: string; client?: string }>;
}) {
  const { locale } = await params;
  const { code, client } = await searchParams;
  const t = await getTranslations({ locale, namespace: "vault.cliAuth" });

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    const returnPath = new URL(localizedVaultPath(locale, "/dashboard/vault/cli-auth"), "https://cmux.com");
    if (code) returnPath.searchParams.set("code", code);
    if (client === "subrouter") {
      returnPath.searchParams.set("client", client);
    }
    redirect(vaultSignInHref(`${returnPath.pathname}${returnPath.search}`));
  }

  const initialCode = typeof code === "string" ? code.toUpperCase() : "";
  const subrouter = client === "subrouter";

  return (
    <div className="mx-auto w-full max-w-3xl px-3 py-4">
      <div className="border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">
          {t(subrouter ? "subrouterEyebrow" : "eyebrow")}
        </p>
        <h1 className="mt-1 text-sm font-medium">
          {t(subrouter ? "subrouterTitle" : "title")}
        </h1>
        <p className="mt-1 max-w-2xl text-muted">
          {t(subrouter ? "subrouterDescription" : "description")}
        </p>
      </div>
      <ApproveForm initialCode={initialCode} />
    </div>
  );
}
