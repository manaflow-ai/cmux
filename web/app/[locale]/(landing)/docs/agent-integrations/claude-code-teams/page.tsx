import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { DocsSchema } from "../../docs-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.claudeCodeTeams" });
  const alternates = buildAlternates(locale, "/docs/agent-integrations/claude-code-teams");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function ClaudeCodeTeamsPage() {
  const t = useTranslations("docs.claudeCodeTeams");

  return (
    <>
      <DocsSchema namespace="docs.claudeCodeTeams" path="/docs/agent-integrations/claude-code-teams" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>

      <p>{t("intro")}</p>

      <video
        src="/blog/cmux-claude-teams-demo.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <DocsHeading level={2} id="usage">{t("usage")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux claude-teams
cmux claude-teams --continue
cmux claude-teams --model sonnet`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <DocsHeading level={2} id="how-it-works">{t("howItWorks")}</DocsHeading>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
      </ul>

      <DocsHeading level={2} id="env-vars">{t("envVars")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("envVarName")}</th>
            <th>{t("envVarPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>TMUX</code></td><td>{t("envTmux")}</td></tr>
          <tr><td><code>TMUX_PANE</code></td><td>{t("envTmuxPane")}</td></tr>
          <tr><td><code>CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS</code></td><td>{t("envTeams")}</td></tr>
          <tr><td><code>CMUX_SOCKET_PATH</code></td><td>{t("envSocket")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="directories">{t("directories")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("dirPath")}</th>
            <th>{t("dirPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>~/.cmuxterm/claude-teams-bin/</code></td><td>{t("dirShim")}</td></tr>
          <tr><td><code>~/.cmuxterm/tmux-compat-store.json</code></td><td>{t("dirStore")}</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="tmux-commands">{t("tmuxCommands")}</DocsHeading>
      <p>{t("tmuxCommandsDesc")}</p>
      <ul>
        <li><code>new-session</code>, <code>new-window</code> &rarr; {t("mapWorkspace")}</li>
        <li><code>split-window</code> &rarr; {t("mapSplit")}</li>
        <li><code>send-keys</code> &rarr; {t("mapSendText")}</li>
        <li><code>capture-pane</code> &rarr; {t("mapReadText")}</li>
        <li><code>select-pane</code>, <code>select-window</code> &rarr; {t("mapFocus")}</li>
        <li><code>kill-pane</code>, <code>kill-window</code> &rarr; {t("mapClose")}</li>
        <li><code>list-panes</code>, <code>list-windows</code> &rarr; {t("mapList")}</li>
      </ul>
    </>
  );
}
