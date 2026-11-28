import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { baseDocsLocales } from "@/app/[locale]/components/docs-nav-items";
import { docsChannel } from "@/app/lib/docs-channel";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

function assertSupportedLocale(locale: string) {
  if (!baseDocsLocales.includes(locale as (typeof baseDocsLocales)[number])) {
    notFound();
  }
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.base" });
  const path = docsChannel() === "nightly" ? "/docs/nightly/base" : "/docs/base";
  const alternates = buildAlternates(locale, path, baseDocsLocales);
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function BasePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.base" });

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <Callout>{t("previewNote")}</Callout>

      <DocsHeading level={2} id="what-is-base">{t("whatTitle")}</DocsHeading>
      <p>{t("whatDesc")}</p>
      <ul>
        <li>{t("whatPersistent")}</li>
        <li>{t("whatSameVm")}</li>
        <li>{t("whatAnywhere")}</li>
      </ul>

      <DocsHeading level={2} id="ownership">{t("ownershipTitle")}</DocsHeading>
      <p>{t("ownershipDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("ownerType")}</th>
            <th>{t("ownerScope")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("personalOwner")}</td><td>{t("personalScope")}</td></tr>
          <tr><td>{t("teamOwner")}</td><td>{t("teamScope")}</td></tr>
        </tbody>
      </table>
      <p>{t("switchingDesc")}</p>

      <DocsHeading level={2} id="open-vs-create">{t("openCreateTitle")}</DocsHeading>
      <p>{t("openCreateDesc")}</p>
      <ul>
        <li>{t("openMeaning")}</li>
        <li>{t("resetMeaning")}</li>
        <li>{t("createMeaning")}</li>
        <li>{t("forkMeaning")}</li>
      </ul>
      <CodeBlock lang="bash">{`# Current preview CLI
cmux vm base open
cmux vm base reset
cmux vm ls
cmux vm status <id>`}</CodeBlock>
      <p>{t("cliNamingDesc")}</p>

      <DocsHeading level={2} id="sessions">{t("sessionsTitle")}</DocsHeading>
      <p>{t("sessionsDesc")}</p>
      <ul>
        <li>{t("sessionScrollback")}</li>
        <li>{t("sessionReconnect")}</li>
        <li>{t("sessionRepair")}</li>
      </ul>

      <DocsHeading level={2} id="mobile">{t("mobileTitle")}</DocsHeading>
      <p>{t("mobileDesc")}</p>

      <DocsHeading level={2} id="notifications">{t("notificationsTitle")}</DocsHeading>
      <p>{t("notificationsDesc")}</p>

      <DocsHeading level={2} id="security">{t("securityTitle")}</DocsHeading>
      <ul>
        <li>{t("securityAuth")}</li>
        <li>{t("securityLease")}</li>
        <li>{t("securityProvider")}</li>
        <li>{t("securityTeam")}</li>
      </ul>

      <DocsHeading level={2} id="recovery">{t("recoveryTitle")}</DocsHeading>
      <p>{t("recoveryDesc")}</p>
      <ul>
        <li>{t("recoveryRetry")}</li>
        <li>{t("recoveryReset")}</li>
        <li>{t("recoverySupport")}</li>
      </ul>
    </>
  );
}
