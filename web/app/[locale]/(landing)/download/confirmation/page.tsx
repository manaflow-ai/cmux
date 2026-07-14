import { getTranslations, setRequestLocale } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { DownloadConfirmation } from "@/app/[locale]/components/download-confirmation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "download" });
  const alternates = buildAlternates(locale, "/download/confirmation");
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
    // Confirmation pages are per-click, not content to index.
    robots: { index: false, follow: true },
  };
}

export default async function DownloadConfirmationPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("download");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <DownloadConfirmation />
    </div>
  );
}
