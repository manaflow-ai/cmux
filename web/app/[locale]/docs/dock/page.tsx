import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.dock" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/dock"),
  };
}

export default function DockPage() {
  const t = useTranslations("docs.dock");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("configTitle")}</h2>
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

      <h2>{t("exampleTitle")}</h2>
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

      <h2>{t("fieldsTitle")}</h2>
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

      <h2>{t("sharingTitle")}</h2>
      <p>{t("sharingIntro")}</p>
      <ul>
        <li>{t("sharingProject")}</li>
        <li>{t("sharingGlobal")}</li>
        <li>{t("sharingSecrets")}</li>
      </ul>

      <h2>{t("agentPromptTitle")}</h2>
      <p>{t("agentPromptIntro")}</p>
      <CodeBlock title={t("agentPromptCodeTitle")} lang="text">
        {t("agentPrompt")}
      </CodeBlock>
    </>
  );
}
