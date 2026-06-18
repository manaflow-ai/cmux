import { getTranslations, setRequestLocale } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { SiteHeader } from "../../components/site-header";
import { DownloadConfirmation } from "../../components/download-confirmation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "download" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/download/confirmation"),
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
