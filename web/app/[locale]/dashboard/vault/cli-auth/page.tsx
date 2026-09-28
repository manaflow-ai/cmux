import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { pendingCliAuthClientForUserCode } from "@/services/vault/cliAuth";
import { ApproveForm } from "./approve-form";


export default async function VaultCliAuthPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ code?: string }>;
}) {
  const { locale } = await params;
  const { code } = await searchParams;
  const t = await getTranslations({ locale, namespace: "vault.cliAuth" });
  const normalizedCode = typeof code === "string"
    ? code.trim().toUpperCase()
    : "";
  const initialCode = /^[A-Z2-9]{8}$/.test(normalizedCode)
    ? normalizedCode
    : "";

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    const returnPath = new URL(localizedVaultPath(locale, "/dashboard/vault/cli-auth"), "https://cmux.com");
    if (initialCode) returnPath.searchParams.set("code", initialCode);
    redirect(vaultSignInHref(`${returnPath.pathname}${returnPath.search}`));
  }

  // The transaction row is the consent authority. Query parameters only carry
  // the user code, so a copied or modified URL cannot relabel another client
  // as CodeRouter. The persisted "subrouter" value is a legacy protocol ID.
  const client = initialCode
    ? await pendingCliAuthClientForUserCode(initialCode, new Date())
    : null;
  const coderouter = client === "subrouter";

  return (
    <div className="mx-auto w-full max-w-3xl px-3 py-4">
      <div className="border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">
          {t(coderouter ? "coderouterEyebrow" : "eyebrow")}
        </p>
        <h1 className="mt-1 text-sm font-medium">
          {t(coderouter ? "coderouterTitle" : "title")}
        </h1>
        <p className="mt-1 max-w-2xl text-muted">
          {t(coderouter ? "coderouterDescription" : "description")}
        </p>
      </div>
      <ApproveForm initialCode={initialCode} />
    </div>
  );
}
