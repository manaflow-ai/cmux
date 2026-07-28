import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { PlatformDownloadPage } from "../platform-download-page";
import { isPlatformDownloadAvailable } from "@/app/lib/download";
import { browserDownloadSeoCopy } from "@/i18n/audited-seo";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";

/** Builds localized metadata for the gated Linux download page. */
export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  if (!isPlatformDownloadAvailable("linux")) notFound();

  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "browserDownloads.linux" });
  const alternates = buildAlternates(locale, "/linux");
  const { title, description } = browserDownloadSeoCopy(locale, t);

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

/** Serves the Linux download page only after its artifacts are published. */
export default function LinuxDownloadPage() {
  if (!isPlatformDownloadAvailable("linux")) notFound();

  return <PlatformDownloadPage platform="linux" />;
}
