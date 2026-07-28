import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { PlatformDownloadPage } from "../platform-download-page";
import { isPlatformDownloadAvailable } from "@/app/lib/download";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";

/** Builds localized metadata for the gated Windows download page. */
export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  if (!isPlatformDownloadAvailable("windows")) notFound();

  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "browserDownloads.windows" });
  const alternates = buildAlternates(locale, "/windows");
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

/** Serves the Windows download page only after its artifacts are published. */
export default function WindowsDownloadPage() {
  if (!isPlatformDownloadAvailable("windows")) notFound();

  return <PlatformDownloadPage platform="windows" />;
}
