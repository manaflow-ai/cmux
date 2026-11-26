import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { DOWNLOAD_CONFIRMATION_HREF } from "@/app/lib/download";
import { installDeeplink, parseInstallReference, installReference } from "@/app/extensions/_lib/refs";
import { loadListing } from "@/app/extensions/_lib/registry";
import { InstallHandoff } from "../extensions/install-handoff";

// A listing page answers with its real status (404 for an unapproved repo) and full HTML for crawlers,
// so it renders before responding instead of streaming into an instant shell.
export const instant = false;

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

export const metadata: Metadata = { robots: { index: false, follow: true } };

/**
 * `/download?install=HOST/OWNER/REPO[/PATH][&commit=SHA][&kind=setup]` (install.md "Handoff"): starts the
 * cmux download and keeps the install link, offering it again when the person comes back. Without a valid
 * `install`, it is the ordinary download confirmation.
 */
export default async function DownloadPage({ searchParams }: { searchParams: SearchParams }) {
  const query = await searchParams;
  const install = typeof query.install === "string" ? parseInstallReference(query.install) : null;
  if (!install) redirect(DOWNLOAD_CONFIRMATION_HREF);
  const commit = typeof query.commit === "string" ? query.commit : null;
  const kind = query.kind === "setup" ? "setup" : "extension";
  const t = await getTranslations("extensions");
  // A link from anywhere can name any repo: say so when cmux.com does not list it.
  const listing = await loadListing(kind, install);
  const name = listing?.name ?? installReference(install);
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("installDownload")} />
      <main className="mx-auto w-full max-w-2xl px-6 py-12">
        <h1 className="text-2xl font-semibold tracking-tight">{t("installDownload")}</h1>
        <p className="mb-8 mt-1 text-[15px] text-muted">{t("installDownloadBody", { name })}</p>
        {listing ? null : (
          <p className="-mt-4 mb-8 rounded-lg border border-border bg-code-bg px-4 py-3 text-[14px] text-muted">{t("notListed", { name })}</p>
        )}
        <InstallHandoff
          href={installDeeplink(install, commit, kind)}
          autoOpen={false}
          autoDownload
          labels={{
            open: t("installOpen"),
            download: t("installDownload"),
            noCmux: t("installNoCmux"),
            downloadBody: t("installDownloadBody", { name }),
          }}
        />
      </main>
    </div>
  );
}
