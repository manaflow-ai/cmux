import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "coderouterOverview",
    path: "/docs/coderouter",
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CoderouterOverviewPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.coderouterOverview" });

  return (
    <>
      <DocsSchema namespace="docs.coderouterOverview" path="/docs/coderouter" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="why">{t("whyTitle")}</DocsHeading>
      <ul>
        <li>{t("whyPool")}</li>
        <li>{t("whyFailover")}</li>
        <li>{t("whyCloud")}</li>
        <li>{t("whyUsage")}</li>
      </ul>

      <DocsHeading level={2} id="accounts">{t("accountsTitle")}</DocsHeading>
      <p>{t("accountsDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("accountColumn")}</th>
            <th>{t("servesColumn")}</th>
            <th>{t("addColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("accountChatgpt")}</td><td>Codex, Pi</td><td><code>cr add codex</code></td></tr>
          <tr><td>{t("accountOpenAiKey")}</td><td>Codex, Pi</td><td>{t("addDashboard")}</td></tr>
          <tr><td>{t("accountOpenRouterKey")}</td><td>Codex, Pi</td><td>{t("addDashboard")}</td></tr>
          <tr><td>{t("accountOpencodeGo")}</td><td>OpenCode</td><td><code>cr add opencode</code></td></tr>
          <tr><td>{t("accountClaudeSubscription")}</td><td>Claude Code</td><td><code>cr add claude</code></td></tr>
          <tr><td>{t("accountAnthropicKey")}</td><td>Claude Code</td><td><code>cmux coderouter claude add api-key</code></td></tr>
          <tr><td>{t("accountBedrock")}</td><td>Claude Code</td><td><code>cmux coderouter claude add bedrock</code></td></tr>
        </tbody>
      </table>
      <p>{t("accountsDashboard")} <Link href="/dashboard/coderouter" className={linkClass}>cmux.com/dashboard/coderouter</Link></p>

      <DocsHeading level={2} id="routing">{t("routingTitle")}</DocsHeading>
      <p>{t("routingSticky")}</p>
      <p>{t("routingFailover")}</p>
      <p>{t("routingProvider")}</p>

      <DocsHeading level={2} id="quickstart">{t("quickstartTitle")}</DocsHeading>
      <ol>
        <li>{t("stepInstall")}</li>
        <li>{t("stepLogin")}</li>
        <li>{t("stepAdd")}</li>
        <li>{t("stepRun")}</li>
      </ol>
      <CodeBlock lang="bash">{`curl -fsSL https://cmux.com/coderouter/install.sh | sh
cr login
cr add codex
cr codex`}</CodeBlock>

      <DocsHeading level={2} id="cloud-machines">{t("cloudTitle")}</DocsHeading>
      <p>{t("cloudDesc")}</p>
      <p><Link href="/docs/coderouter/agents#cloud" className={linkClass}>{t("cloudLink")}</Link></p>

      <DocsHeading level={2} id="teams">{t("teamsTitle")}</DocsHeading>
      <p>{t("teamsScope")}</p>
      <p>{t("teamsPrivate")}</p>
      <p>{t("teamsPersonal")}</p>
      <p>{t("teamsManage")}</p>
      <CodeBlock lang="bash">{`cr org list
cr org switch <name-or-id>
cr accounts
cr transfer [account] [--to <team>]
cr remove [account]`}</CodeBlock>

      <DocsHeading level={2} id="usage">{t("usageTitle")}</DocsHeading>
      <p>{t("usageLimits")}</p>
      <p>{t("usageCr")}</p>
      <p>{t("usageMachines")}</p>
      <p>{t("usageEstimate")}</p>
      <CodeBlock lang="bash">{`cr
cr usage --watch
cmux coderouter machines`}</CodeBlock>

      <DocsHeading level={2} id="credentials">{t("privacyTitle")}</DocsHeading>
      <ul>
        <li>{t("privStored")}</li>
        <li>{t("privArgv")}</li>
        <li>{t("privLocal")}</li>
        <li>{t("privCloud")}</li>
        <li>{t("privRequestId")}</li>
      </ul>

      <DocsHeading level={2} id="next-steps">{t("nextTitle")}</DocsHeading>
      <ul>
        <li><Link href="/docs/coderouter/agents" className={linkClass}>{t("nextAgents")}</Link></li>
        <li><Link href="/docs/coderouter/cli" className={linkClass}>{t("nextCli")}</Link></li>
        <li><Link href="/docs/cloud" className={linkClass}>{t("nextCloud")}</Link></li>
      </ul>
    </>
  );
}
