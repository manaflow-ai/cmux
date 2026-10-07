import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { localizedText, localizedWhatsNewPath } from "@/app/lib/whats-new";
import { whatsNewStore } from "@/app/lib/whats-new-store";
import { whatsNewLabels } from "../labels";
import { WhatsNewDocumentView } from "../whats-new-document";

type PageParams = { locale: string; version: string };

// Every document is known at build time; another version is a 404.
export const dynamicParams = false;

export function generateStaticParams() {
  return whatsNewStore.documents.map((document) => ({ version: document.version }));
}

export async function generateMetadata({ params }: { params: Promise<PageParams> }): Promise<Metadata> {
  const { locale, version } = await params;
  const document = whatsNewStore.find(version);
  if (!document) notFound();
  const t = await getTranslations({ locale, namespace: "whatsNew" });
  const alternates = buildAlternates(locale, `/whats-new/${document.version}`);
  const title = t("versionTitle", { version: document.version });
  const description = seoDescription(locale, localizedText(document.headline, locale));
  return {
    title: { absolute: title },
    description,
    alternates,
    openGraph: { ...openGraphDefaults(locale, "article"), title, description, url: alternates.canonical, publishedTime: document.date },
    twitter: twitterSummary(locale, title, description),
  };
}

/** One release's What's New (the page the app shows after an update, on the web). */
export default async function WhatsNewVersionPage({ params }: { params: Promise<PageParams> }) {
  const { locale, version } = await params;
  const document = whatsNewStore.find(version);
  if (!document) notFound();
  const [t, labels] = await Promise.all([getTranslations({ locale, namespace: "whatsNew" }), whatsNewLabels(locale)]);
  const { newer, older } = whatsNewStore.neighbors(document.version);
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("title")} />
      <main className="w-full max-w-2xl mx-auto px-6 py-10 flex flex-col gap-6">
        <a href={localizedWhatsNewPath(locale)} className="text-[13px] text-muted hover:text-foreground transition-colors">
          <span aria-hidden>&larr;</span> {t("allReleases")}
        </a>
        <WhatsNewDocumentView document={document} locale={locale} labels={labels} />
        {(older || newer) && (
          <nav aria-label={t("releaseNavLabel", { version: document.version })}
            className="flex items-center justify-between border-t border-border pt-6 text-[13px]">
            {older ? (
              <a href={localizedWhatsNewPath(locale, older.version)} className="text-muted hover:text-foreground transition-colors">
                <span aria-hidden>&larr;</span> cmux {older.version}
              </a>
            ) : <span />}
            {newer ? (
              <a href={localizedWhatsNewPath(locale, newer.version)} className="text-muted hover:text-foreground transition-colors">
                cmux {newer.version} <span aria-hidden>&rarr;</span>
              </a>
            ) : <span />}
          </nav>
        )}
      </main>
    </div>
  );
}
