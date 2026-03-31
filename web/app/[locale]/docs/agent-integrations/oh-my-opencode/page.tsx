import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ohMyOpenCode" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function OhMyOpenCodePage() {
  const t = useTranslations("docs.ohMyOpenCode");

  return (
    <>
      <h1>{t("title")}</h1>

      <p>{t("intro")}</p>

      <video
        src="/blog/cmux-omo-demo.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <h2>{t("usage")}</h2>
      <CodeBlock lang="bash">{`cmux omo
cmux omo --continue
cmux omo --model claude-sonnet-4-6`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <h2>{t("whatYouGet")}</h2>
      <p>{t("whatYouGetDesc")}</p>
      <ul>
        <li>{t("whatYouGet1")}</li>
        <li>{t("whatYouGet2")}</li>
        <li>{t("whatYouGet3")}</li>
        <li>{t("whatYouGet4")}</li>
        <li>{t("whatYouGet5")}</li>
      </ul>

      <h2>{t("firstRun")}</h2>
      <p>{t("firstRunDesc")}</p>
      <ol>
        <li>{t("firstRunStep1")}</li>
        <li>{t("firstRunStep2")}</li>
        <li>{t("firstRunStep3")}</li>
        <li>{t("firstRunStep4")}</li>
      </ol>
      <p>{t("firstRunSafe")}</p>

      <h2>{t("howItWorks")}</h2>
      <p>{t("howItWorksDesc")}</p>
      <ul>
        <li>{t("shimStep1")}</li>
        <li>{t("shimStep2")}</li>
        <li>{t("shimStep3")}</li>
        <li>{t("shimStep4")}</li>
        <li>{t("shimStep5")}</li>
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
          <tr><td><code>~/.cmuxterm/omo-bin/</code></td><td>{t("dirShim")}</td></tr>
          <tr><td><code>~/.cmuxterm/omo-config/</code></td><td>{t("dirShadow")}</td></tr>
          <tr><td><code>~/.cmuxterm/tmux-compat-store.json</code></td><td>{t("dirStore")}</td></tr>
        </tbody>
      </table>

      <h2>{t("shadowConfig")}</h2>
      <p>{t("shadowConfigDesc")}</p>
      <ul>
        <li>{t("shadowStep1")}</li>
        <li>{t("shadowStep2")}</li>
        <li>{t("shadowStep3")}</li>
        <li>{t("shadowStep4")}</li>
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
          <tr><td><code>OPENCODE_CONFIG_DIR</code></td><td>{t("envConfigDir")}</td></tr>
          <tr><td><code>CMUX_SOCKET_PATH</code></td><td>{t("envSocket")}</td></tr>
        </tbody>
      </table>
    </>
  );
}
