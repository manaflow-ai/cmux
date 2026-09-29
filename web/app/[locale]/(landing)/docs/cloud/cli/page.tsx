import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudCli",
    path: "/docs/cloud/cli",
  });
}

export default async function CloudCliPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudCli" });

  return (
    <>
      <DocsSchema namespace="docs.cloudCli" path="/docs/cloud/cli" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <p>{t("exitCodes")}</p>

      <DocsHeading level={2} id="auth">{t("authTitle")}</DocsHeading>
      <p>{t("authDesc")}</p>
      <CodeBlock lang="bash">{`cmux auth login
cmux auth status --json
cmux auth logout
cmux auth team list
cmux auth team use <team-id>`}</CodeBlock>

      <DocsHeading level={2} id="machines">{t("lifecycleTitle")}</DocsHeading>
      <p>{t("lifecycleDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm ls [--json]
cmux vm new [--size 4g|8g|16g|24g|32g|64g] [--name <label>] [--workspace <id>] [--window <id>] [--focus true|false] [--detach]
cmux vm base [open] [--detach]
cmux vm base reset [--reason <text>]
cmux vm status <id>
cmux vm stats <id>
cmux vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]
cmux vm rename <id> <label> | --clear
cmux vm pause <id>
cmux vm resume <id>
cmux vm wait <id> [--timeout <seconds>] [--wake]
cmux vm tools <id>
cmux vm ports <id>
cmux vm rm <id>`}</CodeBlock>

      <DocsHeading level={2} id="checkpoints">{t("snapshotsTitle")}</DocsHeading>
      <p>{t("snapshotsDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm snapshot <id> [--name <name>]      # alias: checkpoint
cmux vm snapshot ls <id>
cmux vm snapshot rm <id> <snapshot-id>
cmux vm fork <id> [--name <name>] [--detach]
cmux vm restore <snapshot-id> [--detach]`}</CodeBlock>

      <DocsHeading level={2} id="open">{t("openTitle")}</DocsHeading>
      <p>{t("openDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm shell <id>                         # alias: attach
cmux vm tui <id>                           # full cmux TUI client
cmux vm desktop <id>                       # alias: vnc
cmux vm open <machine>[/<workspace>[/<terminal>[/<tab>]]] [--workspace <id>] [--focus true|false]
cmux vm open <machine>:desktop
cmux vm open <machine>:port/<n> [--print]
cmux vm open <machine> <port> [--print]`}</CodeBlock>

      <DocsHeading level={2} id="run">{t("runTitle")}</DocsHeading>
      <p>{t("runDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm exec [--timeout <seconds>] <id> -- <command...>
cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <size>] [--timeout <seconds>] -- <command...>
cmux vm route [--cwd <dir>] [--new] [--provision] [--size <size>]
cmux vm agent --agent claude|codex|opencode|pi [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--wait [--output] [--timeout <seconds>]] [--new] [--size <size>] -- <prompt>
cmux vm dev <machine> [<local-dir>] [--name <workspace>] [--layout <file>] [--command "<cmd>"] [--port <n>] [--remote <path>] [--sync|--no-sync] [--no-open] [--dry-run]
cmux vm prompt [--open claude|codex|opencode|pi]`}</CodeBlock>

      <DocsHeading level={2} id="workspaces">{t("workspacesTitle")}</DocsHeading>
      <p>{t("workspacesDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm tree [<machine>] [--refresh]
cmux vm workspace new <machine> [--name <name>] [--reuse] [--no-open]
cmux vm workspace open <machine> <workspace-id>
cmux vm workspace rename <machine> <workspace-id> <name>
cmux vm workspace close <machine> <workspace-id>   # terminals keep running
cmux vm workspace rm <machine> <workspace-id>      # terminals stop
cmux vm terminal send <machine> <terminal-id> [text] [--keys <k1,k2>]
cmux vm terminal read <machine> <terminal-id>
cmux vm terminal wait <machine> <terminal-id> --pattern <regex> [--timeout <seconds>]
cmux vm terminal wait-exit <machine> <terminal-id> [--timeout <seconds>]
cmux vm terminal output <machine> <terminal-id> [--after <offset>] [--max-bytes <n>]
cmux vm terminal rename <machine> <terminal-id> <name>
cmux vm terminal close <machine> <terminal-id>
cmux vm layout export <machine> [<workspace>]
cmux vm layout apply <machine> <file>|- [--name <name>] [--cwd <dir>] [--open]`}</CodeBlock>

      <DocsHeading level={2} id="files">{t("filesTitle")}</DocsHeading>
      <p>{t("filesDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes] [--watch]
cmux vm push --secret <id> <local-file> [remote-path] [--mode <octal>]
cmux vm pull <id> <remote-path> [local-path]
cmux vm env set <machine> KEY=VALUE... | --from-file <.env> | -
cmux vm env ls <machine> [--show]
cmux vm env rm <machine> KEY...`}</CodeBlock>

      <DocsHeading level={2} id="domains">{t("domainsTitle")}</DocsHeading>
      <p>{t("domainsDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud domains [list]
cmux cloud domains zones
cmux cloud domains verify <domain>
cmux cloud domains publish <vm> <port> [--domain <hostname>] [--access personal|team|public] [--team <id>] [--yes]
cmux cloud domains access <hostname> personal|team|public [--yes]
cmux cloud domains grant <hostname> <email> [--expires <ISO-date>]
cmux cloud domains ungrant <hostname> <email>
cmux cloud domains grants <hostname>
cmux cloud domains rm <hostname>`}</CodeBlock>

      <DocsHeading level={2} id="vpn">{t("vpnTitle")}</DocsHeading>
      <p>{t("vpnDesc")}</p>
      <CodeBlock lang="bash">{`cmux vpn up
cmux vpn status
cmux vpn down
cmux vpn revoke`}</CodeBlock>

      <DocsHeading level={2} id="ai-accounts">{t("accountsTitle")}</DocsHeading>
      <p>{t("accountsDesc")}</p>
      <CodeBlock lang="bash">{`cmux ai-accounts list
cmux ai-accounts upload claude|codex|anthropic-key|openai-key [--label <label>] [--team <id>]
cmux coderouter status
cmux coderouter machines`}</CodeBlock>

      <DocsHeading level={2} id="scripting-checklist">{t("preflightTitle")}</DocsHeading>
      <p>{t("preflightDesc")}</p>
      <CodeBlock lang="bash">{`cmux auth status
cmux vm ls --json
cmux vm route --json`}</CodeBlock>
    </>
  );
}
