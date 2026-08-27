import { AccountSettings } from "@stackframe/stack";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";


export default async function DashboardTeamPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isStackConfigured()) {
    redirect(`/${locale}`);
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/team")));
  }

  return (
    <div className="w-full px-3 py-4">
      <AccountSettings />
    </div>
  );
}
