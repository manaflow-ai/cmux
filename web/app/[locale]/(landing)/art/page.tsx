import { Suspense } from "react";
import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { ArtGallery } from "./art-gallery";
import { loadArtWorks } from "./art-manifest";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "art" });
  const alternates = buildAlternates(locale, "/art");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

async function Gallery({ locale }: { locale: string }) {
  const works = await loadArtWorks().catch(() => null);
  return <ArtGallery locale={locale} works={works} />;
}

export default function ArtPage() {
  const t = useTranslations("art");
  const locale = useLocale();
  return (
    <div className="min-h-screen">
      <SiteHeader section={t("title")} />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">{t("title")}</h1>
        <p className="text-muted text-[15px] mb-2">{t("description")}</p>
        <p className="text-muted text-[15px] mb-8">{t("howToUse")}</p>
        <Suspense fallback={<p className="text-muted text-[15px]">{t("loading")}</p>}>
          <Gallery locale={locale} />
        </Suspense>
      </main>
    </div>
  );
}
