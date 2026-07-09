import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "@/i18n/seo";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsSchema } from "../docs-schema";

const helloTuiManifest = `{
  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-extension.schema.json",
  "manifestVersion": 1,
  "id": "hello-tui",
  "name": "Hello TUI",
  "version": "0.1.0",
  "description": "Minimal terminal extension demo: prints its cmux context and ticks a clock.",
  "icon": "sparkles",
  "panes": [
    {
      "id": "main",
      "title": "Hello TUI",
      "command": ["./hello.sh"],
      "env": { "HELLO_GREETING": "hi from the manifest env" }
    }
  ]
}`;

const envVars = [
  "CMUX_EXTENSION_ID",
  "CMUX_EXTENSION_PANE_ID",
  "CMUX_EXTENSION_ROOT",
  "CMUX_EXTENSION_CONFIG_DIR",
  "CMUX_EXTENSION_STATE_DIR",
  "CMUX_EXTENSION_ENV",
] as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.extensions" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/extensions"),
  };
}

export default function ExtensionsDocsPage() {
  const t = useTranslations("docs.extensions");

  return (
    <>
      <DocsSchema namespace="docs.extensions" path="/docs/extensions" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="quickstart">{t("quickstartTitle")}</DocsHeading>
      <p>{t("quickstartIntro")}</p>
      <CodeBlock title={t("manifestExampleTitle")} lang="json">
        {helloTuiManifest}
      </CodeBlock>
      <CodeBlock lang="bash">{`cmux extension link ./Examples/extensions/hello-tui
cmux extension install owner/repo`}</CodeBlock>

      <DocsHeading level={2} id="manifest-fields">{t("fieldsTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("fieldHeader")}</th>
            <th>{t("requiredHeader")}</th>
            <th>{t("descriptionHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>manifestVersion</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldManifestVersion")}</td>
          </tr>
          <tr>
            <td><code>id</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldId")}</td>
          </tr>
          <tr>
            <td><code>name</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldName")}</td>
          </tr>
          <tr>
            <td><code>version</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldVersion")}</td>
          </tr>
          <tr>
            <td><code>description</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldDescription")}</td>
          </tr>
          <tr>
            <td><code>minCmuxVersion</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldMinCmuxVersion")}</td>
          </tr>
          <tr>
            <td><code>platforms</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldPlatforms")}</td>
          </tr>
          <tr>
            <td><code>icon</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldIcon")}</td>
          </tr>
          <tr>
            <td><code>build[].command</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldBuild")}</td>
          </tr>
          <tr>
            <td><code>panes[].id</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldPaneId")}</td>
          </tr>
          <tr>
            <td><code>panes[].title</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldPaneTitle")}</td>
          </tr>
          <tr>
            <td><code>panes[].command</code></td>
            <td>{t("requiredYes")}</td>
            <td>{t("fieldPaneCommand")}</td>
          </tr>
          <tr>
            <td><code>panes[].env</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldPaneEnv")}</td>
          </tr>
          <tr>
            <td><code>panes[].cwd</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldPaneCwd")}</td>
          </tr>
          <tr>
            <td><code>panes[].placement</code></td>
            <td>{t("requiredNo")}</td>
            <td>{t("fieldPanePlacement")}</td>
          </tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="environment">{t("envTitle")}</DocsHeading>
      <p>{t("envIntro")}</p>
      <ul>
        {envVars.map((name) => (
          <li key={name}>
            <code>{name}</code> {t(`env.${name}`)}
          </li>
        ))}
      </ul>
      <Callout type="info">{t("cliApiCallout")}</Callout>

      <DocsHeading level={2} id="development">{t("devTitle")}</DocsHeading>
      <p>{t("devIntro")}</p>
      <CodeBlock lang="bash">{`cmux extension link /path/to/extension
cmux extension unlink hello-tui`}</CodeBlock>

      <DocsHeading level={2} id="publishing">{t("publishingTitle")}</DocsHeading>
      <p>{t("publishingIntro")}</p>
      <ol>
        <li>{t("publishingStepManifest")}</li>
        <li>{t("publishingStepPublic")}</li>
        <li>{t("publishingStepSubmit")}</li>
      </ol>

      <DocsHeading level={2} id="trust-and-security">{t("trustTitle")}</DocsHeading>
      <p>{t("trustIntro")}</p>
      <ul>
        <li>{t("trustUnsandboxed")}</li>
        <li>{t("trustValidation")}</li>
        <li>{t("trustPinned")}</li>
        <li>{t("trustConsent")}</li>
      </ul>
      <Callout type="warn">{t("trustCallout")}</Callout>
    </>
  );
}
