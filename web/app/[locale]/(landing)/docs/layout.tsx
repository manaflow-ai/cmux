import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { pruneClientMessages } from "@/i18n/client-messages";
import { buildAlternates, openGraphDefaults } from "@/i18n/seo";
import { DocsNav } from "./docs-nav";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { docsChannel } from "@/app/lib/docs-channel";

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
      ...openGraphDefaults(locale, "article"),
    },
    alternates: buildAlternates(locale, "/docs"),
    robots: channel === "nightly" ? { index: false, follow: true } : undefined,
  };
}

export default async function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const channel = docsChannel();
  // Docs client components read the `docs` namespace, which the shared
  // catalog omits. A nested provider replaces the catalog for this subtree.
  const messages = pruneClientMessages(await getMessages());
  return (
    <NextIntlClientProvider messages={messages}>
      <div className="min-h-screen">
        <SiteHeader section="docs" />
        <DocsNav channel={channel}>
          {children}
        </DocsNav>
      </div>
    </NextIntlClientProvider>
  );
}
