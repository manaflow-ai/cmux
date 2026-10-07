import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { compareWhatsNewVersions, localizedWhatsNewPath, type WhatsNewDocument } from "@/app/lib/whats-new";
import { nightlyDocuments } from "@/app/lib/whats-new-nightly";
import { whatsNewStore } from "@/app/lib/whats-new-store";
import { whatsNewLabels } from "./labels";
import { WhatsNewDocumentView } from "./whats-new-document";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "whatsNew" });
  const alternates = {
    ...buildAlternates(locale, "/whats-new"),
    types: { "application/atom+xml": "/whats-new/feed.xml" },
  };
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: { ...openGraphDefaults(locale, "website"), title, description, url: alternates.canonical },
    twitter: twitterSummary(locale, title, description),
  };
}

/** Nightly digests and releases, newest first in each section. */
export default async function WhatsNewIndexPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const [t, labels, feedNightlies] = await Promise.all([
    getTranslations({ locale, namespace: "whatsNew" }),
    whatsNewLabels(locale),
    nightlyDocuments().catch(() => [] as WhatsNewDocument[]),
  ]);
  const repoNightlies = whatsNewStore.documents.filter((document) => document.channel === "nightly");
  const repoVersions = new Set(repoNightlies.map((document) => document.version));
  const nightlies = [...repoNightlies, ...feedNightlies.filter((document) => !repoVersions.has(document.version))]
    .sort((a, b) => compareWhatsNewVersions(b.version, a.version))
    .slice(0, 10);
  const releases = whatsNewStore.documents.filter((document) => document.channel !== "nightly");
  const section = (title: string, documents: WhatsNewDocument[]) =>
    documents.length === 0 ? null : (
      <section className="flex flex-col gap-2">
        <h2 className="text-[13px] font-semibold text-muted">{title}</h2>
        {documents.map((document) => (
          <div key={document.version} className="border-t border-border pt-8">
            <WhatsNewDocumentView
              document={document}
              locale={locale}
              labels={labels}
              headingLevel={2}
              versionHref={whatsNewStore.find(document.version) ? localizedWhatsNewPath(locale, document.version) : undefined}
            />
          </div>
        ))}
      </section>
    );
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("title")} />
      <main className="w-full max-w-2xl mx-auto px-6 py-10 flex flex-col gap-8">
        <div className="flex flex-col gap-2">
          <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>
          <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            {t("intro")}
          </p>
          <a href="/whats-new/feed.xml" className="text-[13px] text-muted underline underline-offset-2 hover:text-foreground transition-colors">
            {t("feed")}
          </a>
        </div>
        {nightlies.length === 0 && releases.length === 0 && <p className="text-[15px] text-muted">{t("empty")}</p>}
        {section(t("releasesSection"), releases)}
        {section(t("nightlySection"), nightlies)}
      </main>
    </div>
  );
}
