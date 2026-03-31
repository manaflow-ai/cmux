import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.claudeCodeTeams" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function ClaudeCodeTeamsPage() {
  const t = useTranslations("docs.claudeCodeTeams");

  return (
    <>
      <h1>{t("title")}</h1>

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

      <h2>{t("usage")}</h2>
      <CodeBlock lang="bash">{`cmux claude-teams
cmux claude-teams --continue
cmux claude-teams --model sonnet`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <h2>{t("howItWorks")}</h2>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
      </ul>

      <h2>{t("envVars")}</h2>
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

      <h2>{t("directories")}</h2>
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

      <h2>{t("tmuxCommands")}</h2>
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
