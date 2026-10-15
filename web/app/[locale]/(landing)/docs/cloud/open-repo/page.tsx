import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { cloudOpenRepoDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

function assertSupportedLocale(locale: string) {
  if (
    !cloudOpenRepoDocsLocales.includes(
      locale as (typeof cloudOpenRepoDocsLocales)[number],
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
    pageKey: "cloudOpenRepo",
    path: "/docs/cloud/open-repo",
    availableLocales: cloudOpenRepoDocsLocales,
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CloudOpenRepoPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.cloudOpenRepo" });
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  const secretsLink = (chunks: React.ReactNode) => (
    <Link href="/docs/cloud/secrets" className={linkClass}>{chunks}</Link>
  );

  return (
    <>
      <DocsSchema namespace="docs.cloudOpenRepo" path="/docs/cloud/open-repo" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="quick-start">{t("quickStartTitle")}</DocsHeading>
      <p>{t.rich("quickStartDesc", { link: secretsLink })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets import --from-shell
cmux vm secrets import .env --project
cmux vm clone owner/repo --agent claude`}</CodeBlock>

      <DocsHeading level={2} id="what-it-does">{t("stepsTitle")}</DocsHeading>
      <ol>
        <li>{t("stepMachine")}</li>
        <li>{t("stepSecrets")}</li>
        <li>{t("stepClone")}</li>
        <li>{t.rich("stepMissing", { code })}</li>
        <li>{t("stepWorkspace")}</li>
        <li>{t.rich("stepSetup", { code })}</li>
        <li>{t.rich("stepAgent", { code })}</li>
      </ol>
      <CodeBlock lang="bash">{`cmux vm clone owner/repo                   # open the checkout in a Cloud workspace
cmux vm clone owner/repo --agent codex     # also start Codex in it
cmux vm clone . --agent claude -- "run the test suite and fix failures"`}</CodeBlock>

      <DocsHeading level={2} id="which-repos">{t("reposTitle")}</DocsHeading>
      <p>{t("reposDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm clone owner/repo
cmux vm clone https://github.com/owner/repo
cmux vm clone https://github.com/owner/repo/tree/my-branch
cmux vm clone git@github.com:owner/repo.git
cmux vm clone https://git.example.com/team/repo.git
cmux vm clone .`}</CodeBlock>
      <p>{t("reposDot")}</p>

      <DocsHeading level={2} id="options">{t("optionsTitle")}</DocsHeading>
      <p>{t("optionsDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm clone <repo> [--machine <id> | --new] [--size <4g|8g|16g|24g|32g|64g>] [--branch <b>] [--dir <remote-dir>] [--agent claude|codex|opencode|pi [-- <prompt>]] [--setup | --skip-setup] [--no-open] [--focus|--no-focus] [--dry-run] [--json]`}</CodeBlock>

      <DocsHeading level={2} id="private-repos">{t("privateTitle")}</DocsHeading>
      <p>{t.rich("privateDesc", { code, link: secretsLink })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets import --gh`}</CodeBlock>

      <DocsHeading level={2} id="keys-the-repo-needs">{t("declareTitle")}</DocsHeading>
      <p>{t.rich("declareDesc", { code, link: secretsLink })}</p>
      <CodeBlock lang="bash">{`cmux vm secrets check`}</CodeBlock>

      <DocsHeading level={2} id="setup">{t("setupTitle")}</DocsHeading>
      <p>{t.rich("setupDesc", { code })}</p>
      <CodeBlock lang="json">{`// .cmux/cloud.json
{
  "env": [{ "name": "DATABASE_URL", "description": "Postgres for tests" }],
  "setup": ["bun install", "bun run build"]
}`}</CodeBlock>
      <CodeBlock lang="text">{`Missing secrets for owner/repo: DATABASE_URL (from .cmux/cloud.json — "Postgres for tests").
Add: cmux vm secrets set DATABASE_URL --scope project:github.com/owner/repo (continuing without them)
Setup 1/2 bun install … 12.4s ✓
Setup 2/2 bun run build … 31.0s ✓`}</CodeBlock>
      <p>{t.rich("setupFailure", { code })}</p>
      <p>{t.rich("setupTrust", { code })}</p>

      <DocsHeading level={2} id="clone-or-push">{t("pushTitle")}</DocsHeading>
      <p>{t.rich("pushDesc", { code })}</p>

      <DocsHeading level={2} id="next-steps">{t("nextTitle")}</DocsHeading>
      <ul>
        <li><Link href="/docs/cloud/secrets" className={linkClass}>{t("nextSecrets")}</Link></li>
        <li><Link href="/docs/cloud/workspaces" className={linkClass}>{t("nextWorkspaces")}</Link></li>
        <li><Link href="/docs/cloud/cli" className={linkClass}>{t("nextCli")}</Link></li>
      </ul>
    </>
  );
}
