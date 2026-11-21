import { getTranslations } from "next-intl/server";
import { PlatformDownloadPage } from "../platform-download-page";
import { isPlatformDownloadAvailable } from "@/app/lib/download";
import { redirect } from "@/i18n/navigation";
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
  const { locale } = await params;
  // The page redirects while Linux is waitlist-only; no metadata to build.
  if (!isPlatformDownloadAvailable("linux")) return {};

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

/**
 * Serves the Linux download page while Linux downloads are published. While
 * Linux is waitlist-only, `/linux` (linked from older posts and READMEs) sends
 * visitors to the cmux Browser page, whose Linux card offers the waitlist.
 */
export default async function LinuxDownloadPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!isPlatformDownloadAvailable("linux")) {
    redirect({ href: "/browser", locale });
  }

  return <PlatformDownloadPage platform="linux" />;
}
