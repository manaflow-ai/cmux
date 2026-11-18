import type { Metadata } from "next";
import { Suspense } from "react";
import { redirect } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LINK_PAGE_PATH } from "@/app/extensions/_lib/link";
import { readLinkViewer } from "@/app/extensions/_lib/link-session";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { REGISTRY_REPO } from "../listing-index";
import { LinkRepos, type LinkReposLabels } from "./link-repos";

type Params = Promise<{ locale: string }>;

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("extensions");
  // A private, per-person page: never indexed.
  return { title: { absolute: t("linkMetaTitle") }, description: t("linkIntro"), robots: { index: false, follow: false } };
}

/** Link one of your own GitHub repos to its cmux.com extension page, without a pull request to the registry repo. */
export default async function LinkRepoPage({ params }: { params: Params }) {
  const t = await getTranslations("extensions");
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto w-full max-w-4xl px-6 py-10">
        <h1 className="mb-2 text-3xl font-semibold tracking-tight">{t("linkTitle")}</h1>
        <p className="mb-2 max-w-2xl text-[15px] leading-7 text-muted">{t("linkIntro")}</p>
        <p className="mb-8 max-w-2xl text-[13px] leading-6 text-muted">{t("linkUnreviewed", { repo: REGISTRY_REPO })}</p>
        <Suspense fallback={<p className="text-[14px] text-muted">{t("linkLoading")}</p>}>
          <LinkSection params={params} />
        </Suspense>
      </main>
    </div>
  );
}

async function LinkSection({ params }: { params: Params }) {
  const { locale } = await params;
  const t = await getTranslations("extensions");
  const viewer = await readLinkViewer();
  if (viewer.kind === "signed_out") redirect(vaultSignInHref(localizedVaultPath(locale, LINK_PAGE_PATH)));
  if (viewer.kind === "unavailable") {
    return (
      <div className="rounded-2xl border border-dashed border-border px-6 py-8 text-center">
        <p className="text-[15px] font-medium">{t("linkUnavailableTitle")}</p>
        <p className="mt-1 text-[14px] text-muted">{t("linkUnavailableBody")}</p>
        <a href={`/${locale}${LINK_PAGE_PATH}`} className="mt-3 inline-block text-[14px] underline">
          {t("linkRetry")}
        </a>
      </div>
    );
  }
  return <LinkRepos labels={await linkLabels()} />;
}

/** The client's strings, raw: it fills {repo}, {login} and {count} itself. */
async function linkLabels(): Promise<LinkReposLabels> {
  const t = await getTranslations("extensions");
  return {
    loading: t("linkLoading"),
    connectTitle: t("linkConnectTitle"),
    connectBody: t("linkConnectBody"),
    connect: t("linkConnect"),
    connectUnavailable: t("linkConnectUnavailable"),
    connectedAs: t.raw("linkConnectedAs") as string,
    search: t("linkSearch"),
    empty: t("linkEmpty"),
    hiddenPrivate: t.raw("linkHiddenPrivate") as string,
    more: t("linkMore"),
    link: t("linkAction"),
    linking: t("linking"),
    refresh: t("linkRefresh"),
    view: t("linkView"),
    unlink: t("linkUnlink"),
    unlinking: t("unlinking"),
    reviewedBadge: t("linkReviewedBadge"),
    communityBadge: t("linkCommunityBadge"),
    done: t.raw("linkDone") as string,
    alreadyReviewed: t.raw("linkAlreadyReviewed") as string,
    problem: t.raw("linkProblem") as string,
    problemHint: t("linkProblemHint"),
    unlinked: t.raw("linkUnlinked") as string,
    errorNoMarker: t.raw("linkErrorNoMarker") as string,
    errorNotOwner: t.raw("linkErrorNotOwner") as string,
    errorUnavailable: t("linkErrorUnavailable"),
    retry: t("linkRetry"),
  };
}
