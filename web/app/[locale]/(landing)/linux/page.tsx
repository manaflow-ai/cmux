import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { PlatformDownloadPage } from "../platform-download-page";
import { isPlatformDownloadAvailable } from "@/app/lib/download";
import { browserDownloadSeoCopy } from "@/i18n/audited-seo";
import {
  browserOpenGraphDefaults,
  browserTwitterSummary,
  buildAlternates,
} from "@/i18n/seo";

/** Builds localized metadata for the gated Linux download page. */
export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  if (!isPlatformDownloadAvailable("linux")) notFound();

  const { locale } = await params;
  const browser = await getTranslations({
    locale,
    namespace: "browserDownloads",
  });
  const t = await getTranslations({
    locale,
    namespace: "browserDownloads.linux",
  });
  const alternates = buildAlternates(locale, "/linux");
  const { title, description } = browserDownloadSeoCopy(
    locale,
    t,
    browser("eyebrow"),
  );

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...browserOpenGraphDefaults(title),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: browserTwitterSummary(title, description),
  };
}

/** Serves the Linux download page only after its artifacts are published. */
export default function LinuxDownloadPage() {
  if (!isPlatformDownloadAvailable("linux")) notFound();

  return <PlatformDownloadPage platform="linux" />;
}
