import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

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
  {
    id: "release",
    path: "skills/release/SKILL.md",
    command: "./scripts/bump-version.sh",
    nameKey: "releaseName",
    descriptionKey: "releaseDescription",
    useKey: "releaseUse",
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
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("installTitle")}</h2>
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

      <h3>{t("localInstallTitle")}</h3>
      <p>{t("localInstallIntro")}</p>
      <CodeBlock title={t("localInstallCommands")} lang="bash">{`./skills.sh
./skills.sh --list
./skills.sh --skill cmux --skill cmux-browser
./skills.sh --dest ~/.codex/skills
./skills.sh --dry-run`}</CodeBlock>
      <p>{t("pinRefIntro")}</p>
      <CodeBlock lang="bash">{`curl -fsSL https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash -s -- --ref main`}</CodeBlock>

      <h2>{t("includedTitle")}</h2>
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

      <h2>{t("helpMenuTitle")}</h2>
      <p>
        {t.rich("helpMenuIntro", {
          help: (chunks) => <strong>{chunks}</strong>,
          skills: (chunks) => <strong>{chunks}</strong>,
        })}
      </p>

      <h2>{t("authoringTitle")}</h2>
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

      <h2>{t("relatedTitle")}</h2>
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
