import { getTranslations } from "next-intl/server";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { baseDocsLocales } from "@/app/[locale]/components/docs-nav-items";
import { docsChannel } from "@/app/lib/docs-channel";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { notFound } from "next/navigation";

function assertSupportedLocale(locale: string) {
  if (!baseDocsLocales.includes(locale as (typeof baseDocsLocales)[number])) notFound();
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.cloudVpn" });
  const path = docsChannel() === "nightly" ? "/docs/nightly/cloud-vpn" : "/docs/cloud-vpn";
  const alternates = buildAlternates(locale, path, baseDocsLocales);
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: { ...openGraphDefaults(locale, "article"), title, description, url: alternates.canonical },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function CloudVpnPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.cloudVpn" });
  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <Callout>{t("callout")}</Callout>
      <DocsHeading level={2} id="before-you-start">{t("beforeTitle")}</DocsHeading>
      <ul><li>{t("before1")}</li><li>{t("before2")}</li><li>{t("before3")}</li></ul>
      <DocsHeading level={2} id="connect">{t("connectTitle")}</DocsHeading>
      <ol><li>{t("step1")}</li><li>{t("step2")}</li><li>{t("step3")}</li></ol>
      <CodeBlock lang="bash">{`cmux vpn status
cmux vm ls`}</CodeBlock>
      <DocsHeading level={2} id="troubleshooting">{t("troubleshootingTitle")}</DocsHeading>
      <p>{t("troubleshooting")}</p>
    </>
  );
}
