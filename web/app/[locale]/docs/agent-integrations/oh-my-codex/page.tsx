import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ohMyCodex" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function OhMyCodexPage() {
  const t = useTranslations("docs.ohMyCodex");

  return (
    <>
      <h1>{t("title")}</h1>

      <p>{t("intro")}</p>

      <h2>{t("usage")}</h2>
      <CodeBlock lang="bash">{`cmux omx
cmux omx --madmax --high
cmux omx team`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <h2>{t("whatYouGet")}</h2>
      <p>{t("whatYouGetDesc")}</p>
      <ul>
        <li>{t("whatYouGet1")}</li>
        <li>{t("whatYouGet2")}</li>
        <li>{t("whatYouGet3")}</li>
        <li>{t("whatYouGet4")}</li>
      </ul>

      <h2>{t("prerequisites")}</h2>
      <CodeBlock lang="bash">{`npm install -g @openai/codex oh-my-codex
omx setup
omx doctor`}</CodeBlock>
      <p>{t("prerequisitesDesc")}</p>

      <h2>{t("howItWorks")}</h2>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
      </ul>

      <h2>{t("directories")}</h2>
      <table>
        <thead>
          <tr>
            <th>{t("dirPath")}</th>
            <th>{t("dirPurpose")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>~/.cmuxterm/omx-bin/</code></td><td>{t("dirShim")}</td></tr>
          <tr><td><code>~/.cmuxterm/tmux-compat-store.json</code></td><td>{t("dirStore")}</td></tr>
        </tbody>
      </table>

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
          <tr><td><code>CMUX_SOCKET_PATH</code></td><td>{t("envSocket")}</td></tr>
        </tbody>
      </table>
    </>
  );
}
