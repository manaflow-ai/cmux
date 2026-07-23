import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";

export const dynamic = "force-dynamic";

export default async function DashboardIndexPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard")));
  }

  redirect(locale === "en" ? "/home" : `/${locale}/home`);
}
