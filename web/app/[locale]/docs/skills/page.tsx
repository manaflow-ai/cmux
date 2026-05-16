import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

const skills = [
  {
    id: "cmux",
    path: "skills/cmux/SKILL.md",
    command: "cmux identify --json",
    nameKey: "cmuxName",
    descriptionKey: "cmuxDescription",
    useKey: "cmuxUse",
  },
  {
    id: "cmux-workspace",
    path: "skills/cmux-workspace/SKILL.md",
    command: "cmux current-workspace --json",
    nameKey: "workspaceName",
    descriptionKey: "workspaceDescription",
    useKey: "workspaceUse",
  },
  {
    id: "cmux-settings",
    path: "skills/cmux-settings/SKILL.md",
    command: "skills/cmux-settings/scripts/cmux-settings list-supported",
    nameKey: "settingsName",
    descriptionKey: "settingsDescription",
    useKey: "settingsUse",
  },
  {
    id: "cmux-browser",
    path: "skills/cmux-browser/SKILL.md",
    command: "cmux browser surface:2 snapshot --interactive",
    nameKey: "browserName",
    descriptionKey: "browserDescription",
    useKey: "browserUse",
  },
  {
    id: "cmux-markdown",
    path: "skills/cmux-markdown/SKILL.md",
    command: "cmux markdown open plan.md",
    nameKey: "markdownName",
    descriptionKey: "markdownDescription",
    useKey: "markdownUse",
  },
  {
    id: "cmux-debug-windows",
    path: "skills/cmux-debug-windows/SKILL.md",
    command: "skills/cmux-debug-windows/scripts/debug_windows_snapshot.sh",
    nameKey: "debugWindowsName",
    descriptionKey: "debugWindowsDescription",
    useKey: "debugWindowsUse",
  },
] as const;

const skillCoverage = [
  {
    id: "cmux",
    nameKey: "cmuxName",
    scopeKey: "cmuxScope",
    referencesKey: "cmuxReferences",
  },
  {
    id: "cmux-workspace",
    nameKey: "workspaceName",
    scopeKey: "workspaceScope",
    referencesKey: "workspaceReferences",
  },
  {
    id: "cmux-settings",
    nameKey: "settingsName",
    scopeKey: "settingsScope",
    referencesKey: "settingsReferences",
  },
  {
    id: "cmux-browser",
    nameKey: "browserName",
    scopeKey: "browserScope",
    referencesKey: "browserReferences",
  },
  {
    id: "cmux-markdown",
    nameKey: "markdownName",
    scopeKey: "markdownScope",
    referencesKey: "markdownReferences",
  },
  {
    id: "cmux-debug-windows",
    nameKey: "debugWindowsName",
    scopeKey: "debugWindowsScope",
    referencesKey: "debugWindowsReferences",
  },
] as const;

const suggestedSkills = [
  {
    id: "cmux-custom-commands",
    nameKey: "suggestCustomCommandsName",
    useKey: "suggestCustomCommandsUse",
    whyKey: "suggestCustomCommandsWhy",
  },
  {
    id: "cmux-agent-hooks",
    nameKey: "suggestAgentHooksName",
    useKey: "suggestAgentHooksUse",
    whyKey: "suggestAgentHooksWhy",
  },
  {
    id: "cmux-notifications",
    nameKey: "suggestNotificationsName",
    useKey: "suggestNotificationsUse",
    whyKey: "suggestNotificationsWhy",
  },
  {
    id: "cmux-ssh",
    nameKey: "suggestSshName",
    useKey: "suggestSshUse",
    whyKey: "suggestSshWhy",
  },
  {
    id: "cmux-cloud-vm",
    nameKey: "suggestCloudVmName",
    useKey: "suggestCloudVmUse",
    whyKey: "suggestCloudVmWhy",
  },
  {
    id: "cmux-vault",
    nameKey: "suggestVaultName",
    useKey: "suggestVaultUse",
    whyKey: "suggestVaultWhy",
  },
] as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.skills" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/skills"),
  };
}

export default function SkillsPage() {
  const t = useTranslations("docs.skills");

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="install-title">{t("installTitle")}</DocsHeading>
      <p>
        {t.rich("installIntro", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock title={t("installFromGitHub")} lang="bash">{`curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash`}</CodeBlock>
      <Callout type="info">
        {t.rich("installDestination", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </Callout>

      <DocsHeading level={3} id="local-install-title">{t("localInstallTitle")}</DocsHeading>
      <p>{t("localInstallIntro")}</p>
      <CodeBlock title={t("localInstallCommands")} lang="bash">{`./skills.sh
./skills.sh --list
./skills.sh --skill cmux --skill cmux-browser
./skills.sh --dest ~/.codex/skills
./skills.sh --dry-run`}</CodeBlock>
      <p>{t("pinRefIntro")}</p>
      <CodeBlock lang="bash">{`curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash -s -- --ref main`}</CodeBlock>

      <DocsHeading level={2} id="included-title">{t("includedTitle")}</DocsHeading>
      <p>{t("includedIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("skillHeader")}</th>
            <th>{t("useHeader")}</th>
            <th>{t("commandHeader")}</th>
          </tr>
        </thead>
        <tbody>
          {skills.map((skill) => (
            <tr key={skill.id}>
              <td>
                <strong>{t(skill.nameKey)}</strong>
                <br />
                <code>{skill.path}</code>
              </td>
              <td>
                <p>{t(skill.descriptionKey)}</p>
                <p>{t(skill.useKey)}</p>
              </td>
              <td>
                <code>{skill.command}</code>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <DocsHeading level={2} id="coverage-title">{t("coverageTitle")}</DocsHeading>
      <p>{t("coverageIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("skillHeader")}</th>
            <th>{t("scopeHeader")}</th>
            <th>{t("referencesHeader")}</th>
          </tr>
        </thead>
        <tbody>
          {skillCoverage.map((skill) => (
            <tr key={skill.id}>
              <td>
                <strong>{t(skill.nameKey)}</strong>
                <br />
                <code>{skill.id}</code>
              </td>
              <td>{t(skill.scopeKey)}</td>
              <td>{t(skill.referencesKey)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <DocsHeading level={2} id="help-menu-title">{t("helpMenuTitle")}</DocsHeading>
      <p>
        {t.rich("helpMenuIntro", {
          help: (chunks) => <strong>{chunks}</strong>,
          skills: (chunks) => <strong>{chunks}</strong>,
        })}
      </p>

      <DocsHeading level={2} id="authoring-title">{t("authoringTitle")}</DocsHeading>
      <p>{t("authoringIntro")}</p>
      <CodeBlock lang="text">{`skills/<name>/SKILL.md
skills/<name>/agents/openai.yaml
skills/<name>/references/*.md
skills/<name>/scripts/*
skills/<name>/templates/*`}</CodeBlock>
      <Callout>
        {t.rich("authoringCallout", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </Callout>

      <DocsHeading level={2} id="suggestions-title">{t("suggestionsTitle")}</DocsHeading>
      <p>{t("suggestionsIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("suggestionHeader")}</th>
            <th>{t("suggestionUseHeader")}</th>
            <th>{t("suggestionWhyHeader")}</th>
          </tr>
        </thead>
        <tbody>
          {suggestedSkills.map((skill) => (
            <tr key={skill.id}>
              <td>
                <strong>{t(skill.nameKey)}</strong>
                <br />
                <code>{skill.id}</code>
              </td>
              <td>{t(skill.useKey)}</td>
              <td>{t(skill.whyKey)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <Callout type="info">{t("suggestionsCallout")}</Callout>

      <DocsHeading level={2} id="related-title">{t("relatedTitle")}</DocsHeading>
      <ul>
        <li>
          <Link href="/docs/browser-automation">{t("relatedBrowserAutomation")}</Link>
        </li>
        <li>
          <Link href="/docs/api">{t("relatedApi")}</Link>
        </li>
        <li>
          <Link href="/docs/custom-commands">{t("relatedCustomCommands")}</Link>
        </li>
      </ul>
    </>
  );
}
