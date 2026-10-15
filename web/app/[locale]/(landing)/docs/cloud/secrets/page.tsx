import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { cloudSecretsDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

function assertSupportedLocale(locale: string) {
  if (
    !cloudSecretsDocsLocales.includes(
      locale as (typeof cloudSecretsDocsLocales)[number],
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
    pageKey: "cloudSecrets",
    path: "/docs/cloud/secrets",
    availableLocales: cloudSecretsDocsLocales,
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CloudSecretsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.cloudSecrets" });
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  const bold = (chunks: React.ReactNode) => <strong>{chunks}</strong>;

  return (
    <>
      <DocsSchema namespace="docs.cloudSecrets" path="/docs/cloud/secrets" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <Callout type="check">{t("trustSummary")}</Callout>

      <DocsHeading level={2} id="quick-start">{t("quickStartTitle")}</DocsHeading>
      <p>{t("quickStartDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm secrets import --from-shell
cmux vm secrets import .env --project
cmux vm clone owner/repo --agent claude`}</CodeBlock>
      <ol>
        <li>{t.rich("quickStartShell", { code })}</li>
        <li>{t.rich("quickStartProject", { code })}</li>
        <li>
          {t.rich("quickStartClone", {
            code,
            link: (chunks) => (
              <Link href="/docs/cloud/open-repo" className={linkClass}>{chunks}</Link>
            ),
          })}
        </li>
      </ol>

      <DocsHeading level={2} id="how-keys-are-kept">{t("trustTitle")}</DocsHeading>
      <ul>
        <li>{t("trustStore")}</li>
        <li>{t.rich("trustDeliver", { code })}</li>
        <li>{t("trustNever")}</li>
        <li>{t("trustWriteOnly")}</li>
      </ul>
      <Callout type="warn">{t("trustAgents")}</Callout>

      <DocsHeading level={2} id="provider-keys">{t("providerKeysTitle")}</DocsHeading>
      <p>{t("providerKeysDesc")}</p>
      <ul>
        <li>{t.rich("providerKeysOpenAI", { code })}</li>
        <li>{t.rich("providerKeysAnthropic", { code })}</li>
        <li>{t.rich("providerKeysOwnEndpoint", { code })}</li>
        <li>{t("providerKeysRemove")}</li>
      </ul>
      <Callout type="check">{t.rich("providerKeysNever", { code })}</Callout>

      <DocsHeading level={2} id="scopes">{t("scopesTitle")}</DocsHeading>
      <p>{t("scopesDesc")}</p>
      <ul>
        <li>{t.rich("scopeAll", { b: bold })}</li>
        <li>{t.rich("scopeProject", { b: bold, code })}</li>
        <li>{t.rich("scopeMachine", { b: bold })}</li>
      </ul>
      <p>{t("precedenceDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm secrets set ANTHROPIC_API_KEY                     # all machines
cmux vm secrets set DATABASE_URL --project                # this repo's machines
cmux vm secrets set DATABASE_URL --machine brave-otter    # one machine wins over the project value
cmux vm secrets link brave-otter --project .              # link a machine to this repo's project`}</CodeBlock>

      <DocsHeading level={2} id="cli">{t("cliTitle")}</DocsHeading>
      <p>{t("cliDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm secrets ls [--scope all|project[:<key>]|machine:<id>] [--json]
cmux vm secrets set NAME [NAME2...] [--scope <scope> | --project [<key>] | --machine <id>] [--no-sync]
cmux vm secrets import [<.env>|-] [--from-shell [NAME...]] [--gh] [--scope <scope> | --project [<key>] | --machine <id>] [--dry-run] [--no-sync]
cmux vm secrets rm NAME... [--scope <scope> | --project [<key>] | --machine <id>] [--no-sync]
cmux vm secrets sync <machine> [--project <key>|.]
cmux vm secrets status <machine> [--verify] [--json]
cmux vm secrets check [<dir>]
cmux vm secrets link <machine> [--project <key>|.]`}</CodeBlock>
      <p>{t.rich("cliSetDesc", { code })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets set OPENAI_API_KEY          # hidden prompt, nothing is echoed
pbpaste | cmux vm secrets set OPENAI_API_KEY   # read the value from stdin
cmux vm secrets import .env --dry-run       # preview what would change`}</CodeBlock>
      <p>{t.rich("cliImportDesc", { code })}</p>

      <DocsHeading level={2} id="in-the-app">{t("appTitle")}</DocsHeading>
      <ul>
        <li>{t.rich("appOpen", { b: bold })}</li>
        <li>{t("appAdd")}</li>
        <li>{t("appImport")}</li>
        <li>{t.rich("appMachine", { b: bold })}</li>
        <li>{t.rich("appSettings", { b: bold })}</li>
      </ul>

      <DocsHeading level={2} id="when-machines-get-them">{t("syncTitle")}</DocsHeading>
      <p>{t("syncDesc")}</p>
      <p>{t.rich("syncManual", { code })}</p>
      <Callout>{t("syncNewTerminal")}</Callout>

      <DocsHeading level={2} id="rotate-and-revoke">{t("rotateTitle")}</DocsHeading>
      <p>{t.rich("rotateDesc", { code })}</p>
      <p>{t.rich("revokeDesc", { code })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets set ANTHROPIC_API_KEY      # replace the value everywhere it is used
cmux vm secrets rm OLD_SERVICE_TOKEN       # remove it from every machine that got it`}</CodeBlock>
      <Callout type="warn">{t("revokeUpstream")}</Callout>

      <DocsHeading level={2} id="check-a-machine">{t("statusTitle")}</DocsHeading>
      <p>{t.rich("statusDesc", { code })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets status brave-otter --verify`}</CodeBlock>
      <ul>
        <li>{t.rich("statusCurrent", { b: bold })}</li>
        <li>{t.rich("statusStale", { b: bold })}</li>
        <li>{t.rich("statusMissing", { b: bold })}</li>
        <li>{t.rich("statusExtra", { b: bold })}</li>
      </ul>

      <DocsHeading level={2} id="declare-needed-names">{t("declareTitle")}</DocsHeading>
      <p>{t.rich("declareDesc", { code })}</p>
      <CodeBlock lang="json">{`// .cmux/cloud.json
{
  "env": ["ANTHROPIC_API_KEY", "DATABASE_URL", "MAPS_API_KEY"]
}`}</CodeBlock>
      <CodeBlock lang="json">{`// .devcontainer/devcontainer.json
{
  "secrets": {
    "DATABASE_URL": { "description": "Postgres URL for the dev database" }
  }
}`}</CodeBlock>
      <p>{t.rich("declareCheck", { code })}</p>
      <p>{t.rich("declarePreflight", { code })}</p>
      <p>{t.rich("declareApp", { b: bold })}</p>

      <DocsHeading level={2} id="git-auth">{t("gitTitle")}</DocsHeading>
      <p>{t.rich("gitDesc", { code })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets import --gh`}</CodeBlock>
      <p>{t("gitHelper")}</p>
      <p>{t.rich("gitScope", { code })}</p>

      <DocsHeading level={2} id="limits">{t("limitsTitle")}</DocsHeading>
      <ul>
        <li>{t.rich("limitNames", { code })}</li>
        <li>{t.rich("limitReserved", { code })}</li>
        <li>{t.rich("limitSingleLine", { code })}</li>
        <li>{t("limitSize")}</li>
        <li>{t("limitRunningShells")}</li>
        <li>{t("limitPerMac")}</li>
        <li>{t.rich("limitVmEnv", { code })}</li>
      </ul>

      <DocsHeading level={2} id="troubleshooting">{t("troubleTitle")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("symptomColumn")}</th>
            <th>{t("fixColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("errMissing")}</td><td>{t.rich("fixMissing", { code })}</td></tr>
          <tr><td>{t("errOldValue")}</td><td>{t("fixOldValue")}</td></tr>
          <tr><td>{t("errArgv")}</td><td>{t.rich("fixArgv", { code })}</td></tr>
          <tr><td>{t("errMultiline")}</td><td>{t.rich("fixMultiline", { code })}</td></tr>
          <tr><td>{t("errSyncFailed")}</td><td>{t.rich("fixSyncFailed", { code })}</td></tr>
          <tr><td>{t("errGitPrompt")}</td><td>{t.rich("fixGitPrompt", { code })}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="get-help">{t("supportTitle")}</DocsHeading>
      <p>{t("supportDesc")}</p>
    </>
  );
}
