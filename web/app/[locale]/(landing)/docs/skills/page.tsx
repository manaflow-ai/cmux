import { useTranslations } from "next-intl";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

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
    id: "cmux-customization",
    path: "skills/cmux-customization/SKILL.md",
    command: "cmux reload-config",
    nameKey: "customizationName",
    descriptionKey: "customizationDescription",
    useKey: "customizationUse",
  },
  {
    id: "cmux-diagnostics",
    path: "skills/cmux-diagnostics/SKILL.md",
    command: "skills/cmux-diagnostics/scripts/cmux-diagnostics",
    nameKey: "diagnosticsName",
    descriptionKey: "diagnosticsDescription",
    useKey: "diagnosticsUse",
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
    id: "cmux-customization",
    nameKey: "customizationName",
    scopeKey: "customizationScope",
    referencesKey: "customizationReferences",
  },
  {
    id: "cmux-diagnostics",
    nameKey: "diagnosticsName",
    scopeKey: "diagnosticsScope",
    referencesKey: "diagnosticsReferences",
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
] as const;

const suggestedSkills = [
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

const customizationExamples = [
  {
    id: "worktree-agents",
    nameKey: "exampleWorktreeName",
    surfaceKey: "exampleWorktreeSurface",
    useKey: "exampleWorktreeUse",
  },
  {
    id: "full-stack-dev",
    nameKey: "exampleFullStackName",
    surfaceKey: "exampleFullStackSurface",
    useKey: "exampleFullStackUse",
  },
  {
    id: "ssh-devbox",
    nameKey: "exampleSshName",
    surfaceKey: "exampleSshSurface",
    useKey: "exampleSshUse",
  },
  {
    id: "review-pr",
    nameKey: "exampleReviewName",
    surfaceKey: "exampleReviewSurface",
    useKey: "exampleReviewUse",
  },
  {
    id: "docs-workspace",
    nameKey: "exampleDocsName",
    surfaceKey: "exampleDocsSurface",
    useKey: "exampleDocsUse",
  },
  {
    id: "ci-watch",
    nameKey: "exampleCiName",
    surfaceKey: "exampleCiSurface",
    useKey: "exampleCiUse",
  },
  {
    id: "quick-agent-buttons",
    nameKey: "exampleAgentButtonsName",
    surfaceKey: "exampleAgentButtonsSurface",
    useKey: "exampleAgentButtonsUse",
  },
] as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "skills",
    path: "/docs/skills",
  });
}

export default function SkillsPage() {
  const t = useTranslations("docs.skills");

  return (
    <>
      <DocsSchema namespace="docs.skills" path="/docs/skills" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="install-title">{t("installTitle")}</DocsHeading>
      <p>
        {t.rich("installIntro", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock title={t("installWithVercel")} lang="bash">{`# Install all cmux skills
npx skills add manaflow-ai/cmux -g -y

# Or install just diagnostics
npx skills add manaflow-ai/cmux --skill cmux-diagnostics -g -y`}</CodeBlock>
      <CodeBlock title={t("installWithSkillsSh")} lang="bash">{`curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash`}</CodeBlock>
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

      <DocsHeading level={2} id="customization-examples-title">{t("customizationExamplesTitle")}</DocsHeading>
      <p>{t("customizationExamplesIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("exampleHeader")}</th>
            <th>{t("exampleSurfaceHeader")}</th>
            <th>{t("exampleUseHeader")}</th>
          </tr>
        </thead>
        <tbody>
          {customizationExamples.map((example) => (
            <tr key={example.id}>
              <td>
                <strong>{t(example.nameKey)}</strong>
                <br />
                <code>{example.id}</code>
              </td>
              <td>{t(example.surfaceKey)}</td>
              <td>{t(example.useKey)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <Callout type="info">
        {t.rich("customizationExamplesCallout", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </Callout>
      <CodeBlock title={t("customizationExamplePrompts")} lang="text">{[
        t("customizationPromptWorktree"),
        t("customizationPromptFullStack"),
        t("customizationPromptAgentButtons"),
      ].join("\n")}</CodeBlock>

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
