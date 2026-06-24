import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../../components/code-block";
import { DocsHeading } from "../../../components/docs-heading";
import { buildAlternates } from "../../../../../i18n/seo";
import { DocsSchema } from "../../docs-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ohMyCodex" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/agent-integrations/oh-my-codex"),
  };
}

export default function OhMyCodexPage() {
  const t = useTranslations("docs.ohMyCodex");

  return (
    <>
      <DocsSchema namespace="docs.ohMyCodex" path="/docs/agent-integrations/oh-my-codex" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>

      <p>{t("intro")}</p>

      <DocsHeading level={2} id="usage">{t("usage")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux omx
cmux omx --madmax --high
cmux omx team`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <DocsHeading level={2} id="what-you-get">{t("whatYouGet")}</DocsHeading>
      <p>{t("whatYouGetDesc")}</p>
      <ul>
        <li>{t("whatYouGet1")}</li>
        <li>{t("whatYouGet2")}</li>
        <li>{t("whatYouGet3")}</li>
        <li>{t("whatYouGet4")}</li>
      </ul>

      <DocsHeading level={2} id="prerequisites">{t("prerequisites")}</DocsHeading>
      <CodeBlock lang="bash">{`npm install -g @openai/codex oh-my-codex
omx setup
omx doctor`}</CodeBlock>
      <p>{t("prerequisitesDesc")}</p>

      <DocsHeading level={2} id="how-it-works">{t("howItWorks")}</DocsHeading>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
      </ul>

      <DocsHeading level={2} id="directories">{t("directories")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("dirPath")}</th>
            <th>{t("dirPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>~/.cmuxterm/omx-bin/</code></td><td>{t("dirShim")}</td></tr>
          <tr><td><code>~/.cmuxterm/tmux-compat-store.json</code></td><td>{t("dirStore")}</td></tr>
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
          <tr><td><code>TMUX</code></td><td>{t("envTmux")}</td></tr>
          <tr><td><code>TMUX_PANE</code></td><td>{t("envTmuxPane")}</td></tr>
          <tr><td><code>CMUX_SOCKET_PATH</code></td><td>{t("envSocket")}</td></tr>
        </tbody>
      </table>
    </>
  );
}
