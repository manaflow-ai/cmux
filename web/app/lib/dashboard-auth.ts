import { cache } from "react";
import { redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "./stack";
import { localizedVaultPath, vaultSignInHref } from "./vault-auth";

const readDashboardUser = cache(async () => {
  if (!isStackConfigured()) {
    redirect("/");
  }

  return getStackServerApp().getUser({ or: "return-null" });
});

export async function requireDashboardUser(
  locale: string,
  returnPath: string = "/dashboard",
) {
  const user = await readDashboardUser();
  if (!user || user.isAnonymous) {
    redirect(vaultSignInHref(localizedVaultPath(locale, returnPath)));
  }
  return user;
}
