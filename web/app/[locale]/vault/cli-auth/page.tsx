import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { SiteHeader } from "../../components/site-header";
import { ApproveForm } from "./approve-form";

export const dynamic = "force-dynamic";

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

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(signInHref(locale, code ?? ""));
  }

  const initialCode = typeof code === "string" ? code.toUpperCase() : "";

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-3xl px-6 py-12">
        <p className="text-sm font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-2 text-3xl font-semibold">{t("title")}</h1>
        <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">{t("description")}</p>
        <ApproveForm initialCode={initialCode} />
      </main>
    </div>
  );
}

function signInHref(locale: string, code: string): string {
  const returnPath = new URL(`/${locale}/vault/cli-auth`, "https://cmux.com");
  if (code) returnPath.searchParams.set("code", code);
  const afterSignIn = new URL("/handler/after-sign-in", "https://cmux.com");
  afterSignIn.searchParams.set("after_auth_return_to", `${returnPath.pathname}${returnPath.search}`);
  const signIn = new URL("/handler/sign-in", "https://cmux.com");
  signIn.searchParams.set("after_auth_return_to", `${afterSignIn.pathname}${afterSignIn.search}`);
  return `${signIn.pathname}${signIn.search}`;
}
