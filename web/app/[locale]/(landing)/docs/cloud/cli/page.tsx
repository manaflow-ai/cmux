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

      <DocsHeading level={2} id="auth">{t("authTitle")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux cloud sign-in
cmux cloud list-machines
cmux cloud sign-out`}</CodeBlock>

      <DocsHeading level={2} id="machines">{t("lifecycleTitle")}</DocsHeading>
      <p>{t("lifecycleDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud new-machine --size medium --name search-index
cmux cloud new-machine --persistent --size small
cmux cloud list-machines
cmux cloud machine-status --target 'machine:<id>'
cmux cloud resize-machine --target 'machine:<id>' --size large
cmux cloud rename-machine --target 'machine:<id>' --name "billing api"
cmux cloud pause-machine --target 'machine:<id>'
cmux cloud resume-machine --target 'machine:<id>'
cmux cloud set-idle-pause --target 'machine:<id>' --minutes 30
cmux cloud kill-machine --target 'machine:<id>' --confirm`}</CodeBlock>

      <DocsHeading level={2} id="checkpoints">{t("snapshotsTitle")}</DocsHeading>
      <p>{t("snapshotsDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud snapshot-machine --target 'machine:<id>'
cmux cloud fork-machine --target 'machine:<id>'
cmux cloud restore-machine --target 'machine:<id>' --snapshot '<snapshot-id>'
cmux cloud delete-snapshot --target 'machine:<id>' --snapshot '<snapshot-id>' --confirm`}</CodeBlock>

      <DocsHeading level={2} id="open">{t("openTitle")}</DocsHeading>
      <p>{t("openDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud new-terminal-on-machine --target 'machine:<id>' --focus
cmux cloud new-terminal-on-machine --target 'machine:<id>' --workspace '<workspace-id>' --focus
cmux cloud ssh --target 'machine:<id>' --focus
cmux cloud open-browser --target 'machine:<id>' --port 3000
cmux cloud machine-link --target 'machine:<id>' --port 3000`}</CodeBlock>

      <DocsHeading level={2} id="run">{t("runTitle")}</DocsHeading>
      <p>{t("runDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud exec --target 'machine:<id>' --command 'uname -a'
cmux cloud start-session --target 'machine:<id>' --agent codex --cwd /home/cmux
cmux cloud move --target 'tab:<id>' --machine 'machine:<id>'
cmux cloud bring-back --target 'tab:<id>'`}</CodeBlock>

      <DocsHeading level={2} id="files">{t("filesTitle")}</DocsHeading>
      <p>{t("filesDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud files-list --target 'machine:<id>' --path /home/cmux
cmux cloud file-read --target 'machine:<id>' --path /home/cmux/notes.txt
cmux cloud file-write --target 'machine:<id>' --path /home/cmux/notes.txt --contents 'hello'
cmux cloud file-mkdir --target 'machine:<id>' --path /home/cmux/project
cmux cloud file-stat --target 'machine:<id>' --path /home/cmux/notes.txt
cmux cloud file-remove --target 'machine:<id>' --path /home/cmux/notes.txt --confirm
cmux cloud prepare-scp --target 'machine:<id>' --public-key "$(cat ~/.ssh/id_ed25519.pub)"`}</CodeBlock>

      <DocsHeading level={2} id="domains">{t("domainsTitle")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux cloud domain-list
cmux cloud publication-list`}</CodeBlock>

      <DocsHeading level={2} id="scripting-checklist">{t("preflightTitle")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux cloud list-machines
cmux cloud diagnostics`}</CodeBlock>

    </>
  );
}
