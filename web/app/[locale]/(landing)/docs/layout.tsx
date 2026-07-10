import { getTranslations } from "next-intl/server";
import { buildAlternates } from "@/i18n/seo";
import { DocsNav } from "./docs-nav";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { docsChannel, nightlyDocsOrigin, releaseDocsOrigin } from "@/app/lib/docs-channel";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs" });
  const channel = docsChannel();
  return {
    title: {
      template: `%s — ${t("layoutTitle")}`,
      default: t("layoutTitle"),
    },
    openGraph: {
      siteName: "cmux",
      type: "article" as const,
    },
    alternates: buildAlternates(locale, "/docs"),
    robots: channel === "nightly" ? { index: false, follow: true } : undefined,
  };
}

export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const channel = docsChannel();
  return (
    <div className="min-h-screen">
      <SiteHeader section="docs" />
      <DocsNav
        channel={channel}
        releaseOrigin={releaseDocsOrigin()}
        nightlyOrigin={nightlyDocsOrigin()}
      >
        {children}
      </DocsNav>
    </div>
  );
}
