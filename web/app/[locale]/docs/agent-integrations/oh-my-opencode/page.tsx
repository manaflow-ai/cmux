import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../../components/code-block";
import { DocsHeading } from "../../../components/docs-heading";
import { buildAlternates } from "../../../../../i18n/seo";
import { DocsSchema } from "../../docs-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ohMyOpenCode" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/agent-integrations/oh-my-opencode"),
  };
}

export default function OhMyOpenCodePage() {
  const t = useTranslations("docs.ohMyOpenCode");

  return (
    <>
      <DocsSchema namespace="docs.ohMyOpenCode" path="/docs/agent-integrations/oh-my-opencode" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>

      <p>{t("intro")}</p>

      <video
        src="/blog/cmux-omo-demo.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <DocsHeading level={2} id="usage">{t("usage")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux omo
cmux omo --continue
cmux omo --model claude-sonnet-4-6`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <DocsHeading level={2} id="what-you-get">{t("whatYouGet")}</DocsHeading>
      <p>{t("whatYouGetDesc")}</p>
      <ul>
        <li>{t("whatYouGet1")}</li>
        <li>{t("whatYouGet2")}</li>
        <li>{t("whatYouGet3")}</li>
        <li>{t("whatYouGet4")}</li>
        <li>{t("whatYouGet5")}</li>
      </ul>

      <DocsHeading level={2} id="first-run">{t("firstRun")}</DocsHeading>
      <p>{t("firstRunDesc")}</p>
      <ol>
        <li>{t("firstRunStep1")}</li>
        <li>{t("firstRunStep2")}</li>
        <li>{t("firstRunStep3")}</li>
        <li>{t("firstRunStep4")}</li>
      </ol>
      <p>{t("firstRunSafe")}</p>

      <DocsHeading level={2} id="how-it-works">{t("howItWorks")}</DocsHeading>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
        <li>{t("shimStep5")}</li>
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
          <tr><td><code>~/.cmuxterm/omo-bin/</code></td><td>{t("dirShim")}</td></tr>
          <tr><td><code>~/.cmuxterm/omo-config/</code></td><td>{t("dirShadow")}</td></tr>
          <tr><td><code>~/.cmuxterm/tmux-compat-store.json</code></td><td>{t("dirStore")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="shadow-config">{t("shadowConfig")}</DocsHeading>
      <p>{t("shadowConfigDesc")}</p>
      <ul>
        <li>{t("shadowStep1")}</li>
        <li>{t("shadowStep2")}</li>
        <li>{t("shadowStep3")}</li>
        <li>{t("shadowStep4")}</li>
      </ul>

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
          <tr><td><code>OPENCODE_CONFIG_DIR</code></td><td>{t("envConfigDir")}</td></tr>
          <tr><td><code>CMUX_SOCKET_PATH</code></td><td>{t("envSocket")}</td></tr>
        </tbody>
      </table>
    </>
  );
}
