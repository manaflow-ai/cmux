import { notFound, redirect } from "next/navigation";

import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { isValidShareCode } from "@/services/share/token";
import { ShareViewer } from "./share-viewer";

export const dynamic = "force-dynamic";

// A guest opening a share link must be signed in before requesting access;
// the share code alone grants nothing (the host approves each Stack user).
export default async function SharePage({
  params,
}: {
  params: Promise<{ locale: string; code: string }>;
}) {
  const { locale, code } = await params;
  if (!isValidShareCode(code)) {
    notFound();
  }
  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, `/share/${code}`)));
  }
  return <ShareViewer code={code} />;
}
