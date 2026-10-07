import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { localizedWhatsNewPath } from "@/app/lib/whats-new";
import { whatsNewStore } from "@/app/lib/whats-new-store";
import { whatsNewLabels } from "./labels";
import { WhatsNewDocumentView } from "./whats-new-document";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "whatsNew" });
  const alternates = buildAlternates(locale, "/whats-new");
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

/** Every release's What's New, newest first. */
export default async function WhatsNewIndexPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const [t, labels] = await Promise.all([getTranslations({ locale, namespace: "whatsNew" }), whatsNewLabels(locale)]);
  const documents = whatsNewStore.documents;
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("title")} />
      <main className="w-full max-w-2xl mx-auto px-6 py-10 flex flex-col gap-8">
        <div className="flex flex-col gap-2">
          <h1 className="text-2xl font-semibold tracking-tight">{t("title")}</h1>
          <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            {t("intro")}
          </p>
        </div>
        {documents.length === 0 && <p className="text-[15px] text-muted">{t("empty")}</p>}
        {documents.map((document) => (
          <div key={document.version} className="border-t border-border pt-8">
            <WhatsNewDocumentView
              document={document}
              locale={locale}
              labels={labels}
              headingLevel={2}
              versionHref={localizedWhatsNewPath(locale, document.version)}
            />
          </div>
        ))}
      </main>
    </div>
  );
}
