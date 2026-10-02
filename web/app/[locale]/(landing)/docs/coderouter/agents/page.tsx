import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "coderouterAgents",
    path: "/docs/coderouter/agents",
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CoderouterAgentsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.coderouterAgents" });

  return (
    <>
      <DocsSchema namespace="docs.coderouterAgents" path="/docs/coderouter/agents" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <table>
        <thead>
          <tr>
            <th>{t("agentColumn")}</th>
            <th>{t("macColumn")}</th>
            <th>{t("cloudColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>Codex</td><td><code>cr codex</code></td><td>{t("automatic")}</td></tr>
          <tr><td>OpenCode</td><td><code>cr opencode</code></td><td>{t("automatic")}</td></tr>
          <tr><td>Pi</td><td><code>cr pi</code> {t("experimental")}</td><td>{t("automatic")}</td></tr>
          <tr><td>Claude Code</td><td>{t("claudeMacCell")}</td><td>{t("automatic")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="mac">{t("macTitle")}</DocsHeading>
      <p>{t("macDesc")}</p>

      <DocsHeading level={3} id="codex">Codex</DocsHeading>
      <p>{t("codexDesc")}</p>
      <CodeBlock lang="bash">{`cr codex
cr codex exec "fix the failing test"
cr codex -m <model>
cr naked`}</CodeBlock>

      <DocsHeading level={3} id="opencode">OpenCode</DocsHeading>
      <p>{t("opencodeDesc")}</p>
      <CodeBlock lang="bash">{`cr opencode
cr opencode --model <model>`}</CodeBlock>

      <DocsHeading level={3} id="pi">Pi</DocsHeading>
      <p>{t("piDesc")}</p>
      <CodeBlock lang="bash">{`cr pi
cr pi --model <model>`}</CodeBlock>

      <DocsHeading level={3} id="claude-code">{t("claudeTitle")}</DocsHeading>
      <p>{t("claudeDesc")}</p>
      <p>{t("apiKeyCreate")} <Link href="/dashboard/coderouter" className={linkClass}>cmux.com/dashboard/coderouter</Link></p>
      <CodeBlock lang="bash">{`# Claude Code and Anthropic Messages API clients
export ANTHROPIC_BASE_URL=https://coderouter.dev
export ANTHROPIC_API_KEY=crk_...
claude

# OpenAI Responses API clients
export OPENAI_BASE_URL=https://coderouter.dev/v1
export OPENAI_API_KEY=crk_...`}</CodeBlock>
      <p>{t("apiKeyScope")}</p>
      <p>{t("apiKeyLogin")}</p>
      <CodeBlock lang="bash">{`cr login --api-key <key>
CODEROUTER_API_KEY=<key> cr codex exec "run the tests"`}</CodeBlock>

      <DocsHeading level={2} id="cloud">{t("cloudTitle")}</DocsHeading>
      <p>{t("cloudDesc")}</p>
      <ul>
        <li>{t("cloudClaude")}</li>
        <li>{t("cloudCodex")}</li>
        <li>{t("cloudPi")}</li>
        <li>{t("cloudOpencode")}</li>
      </ul>
      <p>{t("cloudYours")}</p>
      <p>{t("cloudRun")}</p>
      <CodeBlock lang="bash">{`# Inside a Cloud machine
claude
codex
cmux coderouter agent claude "summarize the current checkout"

# From your Mac
cmux coderouter agent codex --machine brave-otter -- "run the tests"`}</CodeBlock>
      <p>{t("cloudAccounts")}</p>

      <DocsHeading level={2} id="models">{t("modelsTitle")}</DocsHeading>
      <p>{t("modelsCodex")}</p>
      <p>{t("modelsOpencode")}</p>
      <p>{t("modelsClaude")}</p>
      <p>{t("modelsBedrock")}</p>
      <CodeBlock lang="bash">{`cmux coderouter claude add bedrock --region us-east-1 \\
  --model <claude-model-id>=<bedrock-model-id>`}</CodeBlock>
      <p>{t("modelsList")}</p>
      <CodeBlock lang="bash">{`# Inside a Cloud machine
cmux coderouter models`}</CodeBlock>
    </>
  );
}
