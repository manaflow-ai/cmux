import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";
import { ohMyPiSeoCopy } from "@/i18n/audited-seo";
import {
  fallbackContentLocales,
  hasFallbackContent,
} from "@/i18n/locale-availability";
import { DocsSchema } from "../../docs-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ohMyPi" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const contentLocale = hasFallbackContent(locale) ? locale : "en";
  const alternates = buildAlternates(
    contentLocale,
    "/docs/agent-integrations/oh-my-pi",
    fallbackContentLocales,
  );
  const { title, description } = ohMyPiSeoCopy(
    contentLocale,
    t,
    siteMeta,
  );
  return {
    title: { absolute: title },
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(contentLocale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(contentLocale, title, description),
  };
}

export default function OhMyPiPage() {
  const t = useTranslations("docs.ohMyPi");

  return (
    <>
      <DocsSchema namespace="docs.ohMyPi" path="/docs/agent-integrations/oh-my-pi" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>

      <p>{t("intro")}</p>

      <DocsHeading level={2} id="setup-usage">{t("setupUsage")}</DocsHeading>
      <CodeBlock lang="bash">{`bun install -g @oh-my-pi/pi-coding-agent
# or
brew install can1357/tap/omp

cmux hooks setup omp
# or
cmux hooks omp install`}</CodeBlock>
      <p>{t("setupUsageDesc")}</p>

      <DocsHeading level={2} id="what-you-get">{t("whatYouGet")}</DocsHeading>
      <p>{t("whatYouGetDesc")}</p>
      <ul>
        <li>{t("whatYouGet1")}</li>
        <li>{t("whatYouGet2")}</li>
        <li>{t("whatYouGet3")}</li>
        <li>{t("whatYouGet4")}</li>
        <li>{t("whatYouGet5")}</li>
      </ul>

      <DocsHeading level={2} id="directories">{t("directories")}</DocsHeading>
      <p>{t("directoriesDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("dirPath")}</th>
            <th>{t("dirPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>~/.omp/agent/extensions/cmux-omp-session.ts</code></td><td>{t("dirExtension")}</td></tr>
          <tr><td><code>~/.omp/agent/sessions</code></td><td>{t("dirSessions")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="env-vars">{t("envVars")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("envVarName")}</th>
            <th>{t("envVarPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>CMUX_OMP_HOOKS_DISABLED=1</code></td><td>{t("envHooksDisabled")}</td></tr>
          <tr><td><code>CMUX_OMP_CMUX_BIN</code></td><td>{t("envCmuxBin")}</td></tr>
        </tbody>
      </table>
    </>
  );
}
