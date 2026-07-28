import { getTranslations } from "next-intl/server";
import { PlatformDownloadPage } from "../platform-download-page";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";
import { fallbackContentLocales } from "@/i18n/locale-availability";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "browserDownloads.linux" });
  const alternates = buildAlternates(locale, "/linux", fallbackContentLocales);
  const title = t("metaTitle");
  const description = t("metaDescription");

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

export default function LinuxDownloadPage() {
  return <PlatformDownloadPage platform="linux" />;
}
