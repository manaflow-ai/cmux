import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { cloudSecurityDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { Link } from "@/i18n/navigation";
import { CMUX_REQUIRED_DOMAINS } from "@/services/vms/networkPolicy";

function assertSupportedLocale(locale: string) {
  if (
    !cloudSecurityDocsLocales.includes(
      locale as (typeof cloudSecurityDocsLocales)[number],
    )
  ) {
    notFound();
  }
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudSecurity",
    path: "/docs/cloud-security",
    availableLocales: cloudSecurityDocsLocales,
  });
}

export default async function CloudSecurityPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.cloudSecurity" });
  const bold = (chunks: React.ReactNode) => <strong>{chunks}</strong>;

  return (
    <>
      <DocsSchema namespace="docs.cloudSecurity" path="/docs/cloud-security" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="isolation">{t("isolationTitle")}</DocsHeading>
      <p>{t("isolationVm")}</p>
      <p>{t("isolationRoot")}</p>
      <p>{t("isolationHome")}</p>

      <DocsHeading level={2} id="credentials">{t("credentialsTitle")}</DocsHeading>
      <p>{t("credentialsModel")}</p>
      <p>{t("credentialsAttach")}</p>

      <DocsHeading level={2} id="port-previews">{t("previewsTitle")}</DocsHeading>
      <p>{t("previewsDesc")}</p>

      <DocsHeading level={2} id="outbound-network">{t("networkTitle")}</DocsHeading>
      <p>
        {t.rich("networkIntro", {
          link: (chunks) => <Link href="/dashboard/cloud">{chunks}</Link>,
        })}
      </p>

      <DocsHeading level={3} id="modes">{t("modesTitle")}</DocsHeading>
      <ul>
        <li>{t.rich("modeFull", { b: bold })}</li>
        <li>{t.rich("modeAllowlist", { b: bold })}</li>
        <li>{t.rich("modeNone", { b: bold })}</li>
      </ul>

      <DocsHeading level={3} id="domain-rules">{t("domainsTitle")}</DocsHeading>
      <p>{t("domainsExact")}</p>
      <p>{t("domainsHttps")}</p>
      <p>{t("domainsSteer")}</p>
      <Callout type="warn">{t("domainsBypass")}</Callout>
      <p>{t("presetsDesc")}</p>

      <DocsHeading level={3} id="ip-ranges">{t("rangesTitle")}</DocsHeading>
      <p>{t("rangesDesc")}</p>

      <DocsHeading level={3} id="dns">{t("dnsTitle")}</DocsHeading>
      <p>{t("dnsDesc")}</p>
      <Callout type="warn">{t("dnsRisk")}</Callout>

      <DocsHeading level={3} id="mail-ports">{t("mailTitle")}</DocsHeading>
      <p>{t("mailDesc")}</p>

      <DocsHeading level={3} id="always-allowed-hosts">{t("requiredTitle")}</DocsHeading>
      <p>{t("requiredDesc")}</p>
      <ul>
        {CMUX_REQUIRED_DOMAINS.map((domain) => (
          <li key={domain}><code>{domain}</code></li>
        ))}
      </ul>
      <p>{t("requiredWhy")}</p>

      <DocsHeading level={2} id="hardening-checklist">{t("hardeningTitle")}</DocsHeading>
      <ul>
        <li>{t("hardeningAllowlist")}</li>
        <li>{t("hardeningSecrets")}</li>
        <li>{t("hardeningEdge")}</li>
        <li>{t("hardeningPresets")}</li>
        <li>{t("hardeningDns")}</li>
        <li>{t("hardeningRecreate")}</li>
      </ul>

      <DocsHeading level={2} id="limits">{t("limitsTitle")}</DocsHeading>
      <ul>
        <li>{t("limitsLogs")}</li>
        <li>{t("limitsWildcards")}</li>
        <li>{t("limitsTeam")}</li>
        <li>{t("limitsGithub")}</li>
        <li>{t("limitsBypass")}</li>
      </ul>
    </>
  );
}
