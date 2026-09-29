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

      <DocsHeading level={2} id="durable-terminals">{t("durableTitle")}</DocsHeading>
      <p>{t("durableDesc")}</p>
      <p>{t("durableReconnect")}</p>
      <p>{t("durableRestart")}</p>
      <p>{t("closeVsRemove")}</p>

      <DocsHeading level={2} id="agents">{t("agentsTitle")}</DocsHeading>
      <p>{t("agentsDesc")}</p>
      <p>{t("agentCmdDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm agent --agent claude --machine brave-otter -- "add tests for the parser"
cmux vm agent --agent codex --machine brave-otter --sync --wait -- "fix the build"
cmux vm agent --agent opencode --new --size 16g -- "profile the importer"`}</CodeBlock>
      <p>{t("agentPromptDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm prompt --open claude`}</CodeBlock>

      <DocsHeading level={2} id="run-commands">{t("runTitle")}</DocsHeading>
      <p>{t("runDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm run -- npm test
cmux vm run --sync --pull dist -- npm run build
cmux vm route --json`}</CodeBlock>
      <p>{t("execDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm exec brave-otter -- uname -a
cmux vm exec --timeout 120 brave-otter -- docker ps`}</CodeBlock>

      <DocsHeading level={2} id="dev-server">{t("devTitle")}</DocsHeading>
      <p>{t("devDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm dev brave-otter --dry-run
cmux vm dev brave-otter . --port 3000`}</CodeBlock>

      <DocsHeading level={2} id="notifications">{t("notificationsTitle")}</DocsHeading>
      <p>{t("notificationsDesc")}</p>
      <CodeBlock lang="bash">{`# Inside a Cloud machine
cmux notify --title "Build" --body "Tests passed"`}</CodeBlock>

      <DocsHeading level={2} id="paste-images">{t("imagePasteTitle")}</DocsHeading>
      <p>{t("imagePasteDesc")}</p>

      <DocsHeading level={2} id="layouts">{t("layoutsTitle")}</DocsHeading>
      <p>{t("layoutsDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm tree brave-otter
cmux vm workspace new brave-otter --name review
cmux vm terminal send brave-otter term_2f9c "npm run dev" --keys enter
cmux vm terminal wait brave-otter term_2f9c --pattern "ready" --timeout 60
cmux vm terminal read brave-otter term_2f9c
cmux vm layout export brave-otter review > layout.json
cmux vm layout apply brave-otter layout.json --open`}</CodeBlock>

      <DocsHeading level={2} id="installed-tools">{t("imageTitle")}</DocsHeading>
      <p>{t("imageDesc")}</p>
      <ul>
        <li>{t("imageLanguages")}</li>
        <li>{t("imageBrowser")}</li>
        <li>{t("imageAgents")}</li>
      </ul>
      <p>{t("imageProvisionLog")}</p>

      <DocsHeading level={2} id="model-access">{t("modelsTitle")}</DocsHeading>
      <p>{t("modelsDesc")}</p>
      <CodeBlock lang="bash">{`cmux ai-accounts list
cmux ai-accounts upload claude
cmux coderouter status`}</CodeBlock>

      <DocsHeading level={2} id="guest-cli">{t("guestTitle")}</DocsHeading>
      <p>{t("guestDesc")}</p>
      <CodeBlock lang="bash">{`# Inside a Cloud machine
cmux tree
cmux new-split right
cmux self peers
cmux vm exec calm-heron -- git status`}</CodeBlock>
      <p>{t("guestHostOnly")}</p>

      <DocsHeading level={2} id="iphone">{t("iosTitle")}</DocsHeading>
      <p>{t("iosDesc")}</p>
    </>
  );
}
