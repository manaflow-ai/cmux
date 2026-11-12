import { useTranslations } from "next-intl";
import { getLocale, getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { DocsSchema } from "../docs-schema";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { CopyPrompt } from "@/app/[locale]/components/copy-prompt";

export async function generateMetadata() {
  const locale = await getLocale();
  const t = await getTranslations({ locale, namespace: "docs.computerUse" });
  const title = t("docsMetaTitle");
  const description = t("docsMetaDescription");
  const alternates = buildAlternates(locale, "/docs/computer-use");
  return {
    title, description, alternates,
    openGraph: { ...openGraphDefaults(locale, "article"), title, description, url: alternates.canonical },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function ComputerUseDocs() {
  const t = useTranslations("docs.computerUse");
  return (
    <>
      <DocsSchema namespace="docs.computerUse" path="/docs/computer-use" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <DocsHeading level={2} id="supported-agents">{t("supportTitle")}</DocsHeading>
      <p>{t("supportBody")}</p>
      <DocsHeading level={2} id="setup">{t("setupTitle")}</DocsHeading>
      <ol><li>{t("step1")}</li><li>{t("step2")}</li><li>{t("step3")}</li></ol>
      <DocsHeading level={2} id="copy-prompt">{t("copyTitle")}</DocsHeading>
      <CopyPrompt prompt={t("installPrompt")} copyLabel={t("copyPrompt")} copiedLabel={t("copiedPrompt")} />
      <DocsHeading level={2} id="permissions">{t("permissionsTitle")}</DocsHeading>
      <p>{t("permissionsBody")}</p>
      <p>{t("caption")}</p>
      <p>{t("tahoeBody")}</p>
      <DocsHeading level={2} id="first-task">{t("promptTitle")}</DocsHeading>
      <CodeBlock lang="text">{t("prompt")}</CodeBlock>
      <p>{t("workflowBody")}</p>
      <DocsHeading level={2} id="tools">{t("toolsTitle")}</DocsHeading>
      <p>{t("toolsBody")}</p>
      <DocsHeading level={3} id="codex">Codex</DocsHeading>
      <p>{t("codexBody")}</p>
      <CodeBlock lang="text">{`list_apps, get_app_state, click, perform_secondary_action,
set_value, select_text, scroll, drag, press_key, type_text`}</CodeBlock>
      <DocsHeading level={3} id="claude-code">Claude Code</DocsHeading>
      <p>{t("claudeBody")}</p>
      <CodeBlock lang="text">{`list_apps → list_windows → get_window_state
click / type_text / press_key / scroll / drag
get_window_state`}</CodeBlock>
      <DocsHeading level={2} id="control">{t("controlTitle")}</DocsHeading>
      <p>{t("controlBody")}</p>
      <p>{t("disableBody")}</p>
      <DocsHeading level={2} id="skills">{t("skillTitle")}</DocsHeading>
      <p>{t("skillBody")}</p>
      <p><a href="https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-cua/SKILL.md">{t("skillLink")}</a></p>
      <DocsHeading level={2} id="browser-automation">{t("browserTitle")}</DocsHeading>
      <p>{t("browserBody")}</p>
      <p><Link href="/docs/browser-automation">{t("browserLink")}</Link></p>
      <DocsHeading level={2} id="troubleshooting">{t("troubleTitle")}</DocsHeading>
      <DocsHeading level={3} id="missing-tools">{t("missingTitle")}</DocsHeading>
      <p>{t("missingBody")}</p>
      <DocsHeading level={3} id="permissions-missing">{t("blockedTitle")}</DocsHeading>
      <p>{t("blockedBody")}</p>
      <DocsHeading level={3} id="wrong-target">{t("targetTitle")}</DocsHeading>
      <p>{t("targetBody")}</p>
      <p><Link href="/cua">{t("productLink")}</Link></p>
    </>
  );
}
