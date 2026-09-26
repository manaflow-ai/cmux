import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { customSidebarDocsLocales } from "@/i18n/locale-availability";

function assertSupportedLocale(locale: string) {
  if (
    !customSidebarDocsLocales.includes(
      locale as (typeof customSidebarDocsLocales)[number],
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
    pageKey: "customSidebars",
    path: "/docs/custom-sidebars",
    availableLocales: customSidebarDocsLocales,
  });
}

export default async function CustomSidebarsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.customSidebars" });

  return (
    <>
      <DocsSchema namespace="docs.customSidebars" path="/docs/custom-sidebars" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <Callout>{t("betaNote")}</Callout>

      <DocsHeading level={2} id="quick-start">{t("quickStartTitle")}</DocsHeading>
      <p>{t("quickStartIntro")}</p>
      <CodeBlock title="~/.config/cmux/sidebars/roster.swift" lang="swift">{`VStack(alignment: .leading, spacing: 6) {
    Text("ROSTER").font(.headline)
    Divider()
    for workspace in workspaces.prefix(30) {
        if let agents = workspace.agents {
            for agent in agents {
                Button(action: {
                    cmux("surface.focus", surface_id: agent.surfaceId,
                         workspace_id: agent.workspaceId)
                }) {
                    HStack {
                        Text(agent.name)
                        Spacer()
                        Text(agent.status).font(.caption).secondary()
                    }
                }
            }
        }
    }
}`}</CodeBlock>
      <p>{t("quickStartCommands")}</p>
      <CodeBlock lang="bash">{`cmux sidebar validate roster
cmux sidebar open roster`}</CodeBlock>

      <DocsHeading level={2} id="files">{t("filesTitle")}</DocsHeading>
      <p>{t("filesIntro")}</p>
      <ul>
        <li><code>~/.config/cmux/sidebars/&lt;name&gt;.swift</code> {t("swiftFile")}</li>
        <li><code>~/.config/cmux/sidebars/&lt;name&gt;.js</code> {t("jsFile")}</li>
        <li><code>~/.config/cmux/sidebars/&lt;name&gt;.json</code> {t("jsonFile")}</li>
      </ul>
      <p>{t("reloadIntro")}</p>

      <DocsHeading level={2} id="data">{t("dataTitle")}</DocsHeading>
      <p>{t("dataIntro")}</p>
      <ul>
        <li>{t("dataWorkspace")}</li>
        <li>{t("dataTabs")}</li>
        <li>{t("dataClock")}</li>
      </ul>

      <DocsHeading level={3} id="agents">{t("agentsTitle")}</DocsHeading>
      <p>{t("agentsIntro")}</p>
      <table>
        <thead>
          <tr><th>{t("fieldHeader")}</th><th>{t("descriptionHeader")}</th></tr>
        </thead>
        <tbody>
          <tr><td><code>id</code></td><td>{t("agentId")}</td></tr>
          <tr><td><code>workspaceId</code></td><td>{t("agentWorkspaceId")}</td></tr>
          <tr><td><code>kind</code>, <code>name</code></td><td>{t("agentKindName")}</td></tr>
          <tr><td><code>status</code></td><td>{t("agentStatus")}</td></tr>
          <tr><td><code>children</code></td><td>{t("agentChildren")}</td></tr>
          <tr><td><code>panelId</code>, <code>surfaceId</code></td><td>{t("agentTargets")}</td></tr>
        </tbody>
      </table>
      <Callout type="info">{t("identityCallout")}</Callout>

      <DocsHeading level={2} id="actions">{t("actionsTitle")}</DocsHeading>
      <p>{t("actionsIntro")}</p>
      <ul>
        <li><code>workspace.select</code> {t("workspaceSelect")}</li>
        <li><code>surface.focus</code> {t("surfaceFocus")}</li>
        <li><code>workspace.reorder</code> {t("workspaceReorder")}</li>
      </ul>

      <DocsHeading level={2} id="renderer">{t("rendererTitle")}</DocsHeading>
      <p>{t("rendererIntro")}</p>
      <CodeBlock lang="json">{`{
  "customSidebars": { "renderer": "inProcess" }
}`}</CodeBlock>

      <DocsHeading level={2} id="source">{t("sourceTitle")}</DocsHeading>
      <p>
        {t("sourceIntro")} {" "}
        <a href="https://github.com/manaflow-ai/cmux/blob/main/docs/custom-sidebars.md">
          {t("sourceLink")}
        </a>
        .
      </p>
    </>
  );
}
