import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { vaultSignInHref } from "../../lib/vault-auth";
import { ShareWorkspaceClient, type ShareWorkspaceCopy } from "./ShareWorkspaceClient";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function generateMetadata(): Promise<Metadata> {
  const locale = japanesePreferred((await headers()).get("accept-language")) ? "ja" : "en";
  const t = await getTranslations({ locale, namespace: "workspaceShare" });
  return {
    title: t("metaTitle"),
    robots: { index: false, follow: false, nocache: true },
    referrer: "no-referrer",
  };
}

export default async function ShareWorkspacePage({
  params,
}: {
  params: Promise<{ shareId: string }>;
}) {
  const { shareId } = await params;
  if (!/^[A-Za-z0-9_-]{22}$/.test(shareId)) notFound();
  if (!isStackConfigured()) notFound();
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user || user.isAnonymous) redirect(vaultSignInHref(`/share/${shareId}`));
  const locale = japanesePreferred((await headers()).get("accept-language")) ? "ja" : "en";
  const t = await getTranslations({ locale, namespace: "workspaceShare" });
  if (!user.primaryEmailVerified) {
    return (
      <main className="share-page">
        <section className="share-status-card">
          <h1>{t("verifiedEmailTitle")}</h1>
          <p>{t("verifiedEmailDescription")}</p>
        </section>
      </main>
    );
  }
  const copy: ShareWorkspaceCopy = {
    connecting: t("connecting"),
    reconnecting: t("reconnecting"),
    pendingTitle: t("pendingTitle"),
    pendingDescription: t("pendingDescription"),
    deniedTitle: t("deniedTitle"),
    deniedDescription: t("deniedDescription"),
    endedTitle: t("endedTitle"),
    endedDescription: t("endedDescription"),
    errorTitle: t("errorTitle"),
    errorDescription: t("errorDescription"),
    workspaceWaiting: t("workspaceWaiting"),
    chatTitle: t("chatTitle"),
    chatPlaceholder: t("chatPlaceholder"),
    send: t("send"),
    participants: t("participants"),
    terminalWaiting: t("terminalWaiting"),
    terminalInputLabel: t("terminalInputLabel"),
    browserWaiting: t("browserWaiting"),
    unsupportedPanel: t("unsupportedPanel"),
    textBoxLabel: t("textBoxLabel"),
    privacy: t("privacy"),
  };
  return <ShareWorkspaceClient shareId={shareId} copy={copy} />;
}

function japanesePreferred(value: string | null): boolean {
  if (!value) return false;
  const first = value.split(",")[0]?.trim().toLowerCase() ?? "";
  return first === "ja" || first.startsWith("ja-");
}
