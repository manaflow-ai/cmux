import { useTranslations } from "next-intl";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "dock",
    path: "/docs/dock",
  });
}

export default function DockPage() {
  const t = useTranslations("docs.dock");

  return (
    <>
      <DocsSchema namespace="docs.dock" path="/docs/dock" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="config-title">{t("configTitle")}</DocsHeading>
      <p>{t("configIntro")}</p>
      <ol>
        <li>
          <code>.cmux/dock.json</code> {t("projectConfig")}
        </li>
        <li>
          <code>~/.config/cmux/dock.json</code> {t("globalConfig")}
        </li>
      </ol>
      <Callout type="info">{t("precedenceCallout")}</Callout>
      <Callout type="warn">{t("trustCallout")}</Callout>

      <DocsHeading level={2} id="example-title">{t("exampleTitle")}</DocsHeading>
      <p>{t("exampleIntro")}</p>
      <CodeBlock title=".cmux/dock.json" lang="json">{`{
  "controls": [
    {
      "id": "git",
      "title": "Git",
      "command": "lazygit",
      "height": 300
    },
    {
      "id": "logs",
      "title": "Logs",
      "command": "tail -f ./logs/development.log",
      "cwd": "."
    },
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui --opentui",
      "height": 320
    }
  ]
}`}</CodeBlock>

      <DocsHeading level={2} id="fields-title">{t("fieldsTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("fieldHeader")}</th>
            <th>{t("descriptionHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>
              <code>id</code>
            </td>
            <td>{t("fieldId")}</td>
          </tr>
          <tr>
            <td>
              <code>title</code>
            </td>
            <td>{t("fieldTitle")}</td>
          </tr>
          <tr>
            <td>
              <code>command</code>
            </td>
            <td>{t("fieldCommand")}</td>
          </tr>
          <tr>
            <td>
              <code>cwd</code>
            </td>
            <td>{t("fieldCwd")}</td>
          </tr>
          <tr>
            <td>
              <code>height</code>
            </td>
            <td>{t("fieldHeight")}</td>
          </tr>
          <tr>
            <td>
              <code>env</code>
            </td>
            <td>{t("fieldEnv")}</td>
          </tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="sharing-title">{t("sharingTitle")}</DocsHeading>
      <p>{t("sharingIntro")}</p>
      <ul>
        <li>{t("sharingProject")}</li>
        <li>{t("sharingGlobal")}</li>
        <li>{t("sharingSecrets")}</li>
      </ul>

      <DocsHeading level={2} id="agent-prompt-title">{t("agentPromptTitle")}</DocsHeading>
      <p>{t("agentPromptIntro")}</p>
      <CodeBlock title={t("agentPromptCodeTitle")} lang="text">
        {t("agentPrompt")}
      </CodeBlock>
    </>
  );
}
