import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudWorkspaces",
    path: "/docs/cloud/workspaces",
  });
}

export default async function CloudWorkspacesPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudWorkspaces" });

  return (
    <>
      <DocsSchema namespace="docs.cloudWorkspaces" path="/docs/cloud/workspaces" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="layouts">{t("layoutsTitle")}</DocsHeading>
      <p>{t("layoutsDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud list-machines
cmux cloud new-terminal-on-machine --target 'machine:<id>' --focus
cmux cloud new-terminal-on-machine --target 'machine:<id>' --workspace '<workspace-id>' --focus
cmux cloud ssh --target 'machine:<id>' --focus`}</CodeBlock>

      <DocsHeading level={2} id="durable-terminals">{t("durableTitle")}</DocsHeading>
      <p>{t("durableDesc")}</p>
      <p>{t("durableReconnect")}</p>
      <p>{t("durableRestart")}</p>

      <DocsHeading level={2} id="agents">{t("agentsTitle")}</DocsHeading>
      <p>{t("agentCmdDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud start-session --target 'machine:<id>' --agent codex --cwd /home/cmux
cmux cloud move --target 'tab:<id>' --machine 'machine:<id>'
cmux cloud bring-back --target 'tab:<id>'`}</CodeBlock>

      <DocsHeading level={2} id="run-commands">{t("runTitle")}</DocsHeading>
      <p>{t("execDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud exec --target 'machine:<id>' --command 'uname -a'
cmux cloud exec --target 'machine:<id>' --command 'git -C /home/cmux/project status'`}</CodeBlock>

      <DocsHeading level={2} id="dev-server">{t("devTitle")}</DocsHeading>
      <p>{t("devDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud open-browser --target 'machine:<id>' --port 3000
cmux cloud machine-link --target 'machine:<id>' --port 3000`}</CodeBlock>

      <DocsHeading level={2} id="paste-images">{t("imagePasteTitle")}</DocsHeading>
      <p>{t("imagePasteDesc")}</p>

    </>
  );
}
