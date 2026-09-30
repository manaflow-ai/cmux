import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "coderouterCli",
    path: "/docs/coderouter/cli",
  });
}

export default async function CoderouterCliPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.coderouterCli" });

  return (
    <>
      <DocsSchema namespace="docs.coderouterCli" path="/docs/coderouter/cli" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="install">{t("installTitle")}</DocsHeading>
      <p>{t("installDesc")}</p>
      <CodeBlock lang="bash">{`curl -fsSL https://cmux.com/coderouter/install.sh | sh
npm install -g coderouter
uv tool install coderouter`}</CodeBlock>
      <p>{t("loginDesc")}</p>
      <CodeBlock lang="bash">{`cr login
cr login --device-auth
cr login --code [code-or-url]
cr logout`}</CodeBlock>

      <DocsHeading level={2} id="cr">{t("crTitle")}</DocsHeading>
      <p>{t("crDesc")}</p>
      <CodeBlock lang="bash">{`cr                             # account and usage summary
cr codex [arguments...]
cr opencode [arguments...]
cr pi [arguments...]           # experimental
cr naked [arguments...]        # plain Codex, CodeRouter bypassed (alias: direct)
cr add                         # choose a provider
cr add codex
cr add claude [--label <name>] [--stdin]
cr add opencode
cr remove [account] [--yes]
cr transfer [account] [--to <team>] [--yes]
cr accounts [--watch] [--json] # aliases: list, ls, usage
cr org current | list | switch <name-or-id>
cr login [--api-key <key>] [--device-auth] [--code [code-or-url]]
cr logout
cr doctor
cr upgrade`}</CodeBlock>
      <p>{t("crAddCodex")}</p>

      <DocsHeading level={2} id="cmux-coderouter">{t("cmuxTitle")}</DocsHeading>
      <p>{t("cmuxDesc")}</p>
      <CodeBlock lang="bash">{`cmux coderouter status
cmux coderouter machines
cmux coderouter claude list
cmux coderouter claude add oauth-token [--label <name>] [--stdin]
cmux coderouter claude add api-key [--label <name>] [--stdin]
cmux coderouter claude add bedrock [--label <name>] [--region <region>] [--model <claude-id>=<bedrock-id>]...
cmux coderouter claude disable <account>
cmux coderouter claude enable <account>
cmux coderouter claude remove <account>
cmux coderouter claude clear
cmux coderouter agent <claude|codex|opencode|pi> [vm-agent-options] -- <prompt>`}</CodeBlock>
      <p>{t("claudeAddDesc")}</p>
      <p>{t("accountSelector")}</p>
      <p>{t("passthroughDesc")}</p>
      <CodeBlock lang="bash">{`cmux cr accounts
cmux coderouter login`}</CodeBlock>

      <DocsHeading level={2} id="inside-a-machine">{t("guestTitle")}</DocsHeading>
      <p>{t("guestDesc")}</p>
      <CodeBlock lang="bash">{`cmux auth status [--json]
cmux coderouter status [--json]
cmux coderouter usage [--json|--tsv] [--days <n>]
cmux coderouter models
cmux coderouter accounts [--json]
cmux coderouter org current [--json]
cmux coderouter agent <claude|codex|opencode|pi> [--timeout <seconds>] [args...]`}</CodeBlock>

      <DocsHeading level={2} id="troubleshooting">{t("troubleTitle")}</DocsHeading>
      <p>{t("troubleDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("symptomColumn")}</th>
            <th>{t("fixColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("errSignIn")}</td><td>{t("fixSignIn")}</td></tr>
          <tr><td>{t("errExpired")}</td><td>{t("fixExpired")}</td></tr>
          <tr><td>{t("errNoCodex")}</td><td>{t("fixNoCodex")}</td></tr>
          <tr><td>{t("errNoClaude")}</td><td>{t("fixNoClaude")}</td></tr>
          <tr><td>{t("errClaudeCooling")}</td><td>{t("fixClaudeCooling")}</td></tr>
          <tr><td>{t("errBedrockModel")}</td><td>{t("fixBedrockModel")}</td></tr>
          <tr><td>{t("errBedrockRegion")}</td><td>{t("fixBedrockRegion")}</td></tr>
          <tr><td>{t("errNotInstalled")}</td><td>{t("fixNotInstalled")}</td></tr>
          <tr><td>{t("errAgentMissing")}</td><td>{t("fixAgentMissing")}</td></tr>
          <tr><td>{t("errCodexLoop")}</td><td>{t("fixCodexLoop")}</td></tr>
          <tr><td>{t("errOpencodeModel")}</td><td>{t("fixOpencodeModel")}</td></tr>
          <tr><td>{t("errOpencodeMachine")}</td><td>{t("fixOpencodeMachine")}</td></tr>
          <tr><td>{t("errEdge")}</td><td>{t("fixEdge")}</td></tr>
          <tr><td>{t("errUnavailable")}</td><td>{t("fixUnavailable")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="diagnose">{t("diagnoseTitle")}</DocsHeading>
      <p>{t("diagnoseDesc")}</p>
      <CodeBlock lang="bash">{`cr doctor
cmux coderouter status`}</CodeBlock>

      <DocsHeading level={2} id="get-help">{t("supportTitle")}</DocsHeading>
      <p>{t("supportDesc")}</p>
    </>
  );
}
