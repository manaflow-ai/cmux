import { useTranslations } from "next-intl";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Link } from "@/i18n/navigation";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "workspaceGroups",
    path: "/docs/workspace-groups",
  });
}

const GROUP_SHORTCUT = "⌘⇧G";
const NEW_WORKSPACE_SHORTCUT = "⌘N";

export default function WorkspaceGroupsPage() {
  const t = useTranslations("docs.workspaceGroups");

  return (
    <>
      <DocsSchema namespace="docs.workspaceGroups" path="/docs/workspace-groups" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="concepts">{t("concepts")}</DocsHeading>

      <DocsHeading level={3} id="anchor-workspace">{t("anchorTitle")}</DocsHeading>
      <p>{t("anchorDesc")}</p>
      <p>{t("anchorNew")}</p>
      <p>{t("anchorClose")}</p>

      <DocsHeading level={3} id="group-identity">{t("identityTitle")}</DocsHeading>
      <p>{t("identityDesc")}</p>

      <DocsHeading level={3} id="pinning">{t("pinningTitle")}</DocsHeading>
      <p>{t("pinningDesc")}</p>
      <p>{t("layoutIntro")}</p>
      <ol>
        <li>{t("layoutItem1")}</li>
        <li>{t("layoutItem2")}</li>
      </ol>

      <DocsHeading level={2} id="creating-a-group">{t("creatingTitle")}</DocsHeading>
      <p>{t("creatingIntro")}</p>

      <DocsHeading level={3} id="from-the-keyboard">
        {t("keyboardTitle", { shortcut: GROUP_SHORTCUT })}
      </DocsHeading>
      <p>{t("keyboardDesc", { shortcut: GROUP_SHORTCUT })}</p>
      <Callout type="info">{t("keyboardNote", { shortcut: GROUP_SHORTCUT })}</Callout>
      <p>{t("keyboardSingle")}</p>

      <DocsHeading level={3} id="from-a-workspace-context-menu">{t("contextMenuTitle")}</DocsHeading>
      <p>{t("contextMenuDesc")}</p>

      <DocsHeading level={2} id="managing-a-group">{t("managingTitle")}</DocsHeading>
      <p>{t("managingIntro")}</p>

      <DocsHeading level={3} id="from-the-group-header-context-menu">{t("headerMenuTitle")}</DocsHeading>
      <p>{t("headerMenuDesc")}</p>

      <DocsHeading level={3} id="from-the-plus-button">{t("plusButtonTitle")}</DocsHeading>
      <p>{t("plusButtonDesc")}</p>
      <p>{t("plusButtonNote", { shortcut: NEW_WORKSPACE_SHORTCUT })}</p>

      <DocsHeading level={2} id="cli">{t("cliTitle")}</DocsHeading>
      <p>{t("cliDesc")}</p>

      <DocsHeading level={3} id="subcommands">{t("cliSubcommandsTitle")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux workspace-group list [--json]
cmux workspace-group create --name "manaflow" [--cwd ~/projects/manaflow] [--from <id>,<id>]
cmux workspace-group ungroup <group-id>
cmux workspace-group delete  <group-id>
cmux workspace-group rename <group-id> --name "new name"
cmux workspace-group collapse <group-id>
cmux workspace-group expand <group-id>
cmux workspace-group pin <group-id>
cmux workspace-group unpin <group-id>
cmux workspace-group add --group <group-id> --workspace <workspace-id>
cmux workspace-group remove --workspace <workspace-id>
cmux workspace-group set-anchor --group <group-id> --workspace <workspace-id>
cmux workspace-group new-workspace <group-id> [--placement afterCurrent|top|end]
cmux workspace-group set-color <group-id> --hex "#7A4FD8"
cmux workspace-group set-icon  <group-id> --symbol ladybug.fill
cmux workspace-group move <group-id> (--to-index <n> | --before <group-id> | --after <group-id>)
cmux workspace-group focus <group-id>`}</CodeBlock>
      <p>{t("cliCreateNote")}</p>
      <p>{t("cliFlagsNote")}</p>

      <DocsHeading level={3} id="examples">{t("cliExamplesTitle")}</DocsHeading>
      <p>{t("cliExampleGroup")}</p>
      <CodeBlock lang="bash">{`cmux workspace-group create --name manaflow`}</CodeBlock>
      <p>{t("cliExampleNew")}</p>
      <CodeBlock lang="bash">{`cmux workspace-group new-workspace workspace_group:1`}</CodeBlock>
      <p>{t("cliExampleList")}</p>
      <CodeBlock lang="bash">{`cmux workspace-group list`}</CodeBlock>

      <DocsHeading level={2} id="configuration">{t("configTitle")}</DocsHeading>
      <p>{t("configNote")}</p>
      <p>
        <Link href="/docs/configuration#schema-workspaceGroups">{t("configLinkText")}</Link>
      </p>

      <DocsHeading level={2} id="persistence">{t("persistenceTitle")}</DocsHeading>
      <p>{t("persistenceDesc")}</p>
    </>
  );
}
