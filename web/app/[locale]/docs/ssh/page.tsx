import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.ssh" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/ssh"),
  };
}

export default function SshPage() {
  const t = useTranslations("docs.ssh");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/RoR9pMOZWkk"
        title="cmux SSH demo"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />

      <h2>{t("usage")}</h2>
      <CodeBlock lang="bash">{`cmux ssh user@remote
cmux ssh user@remote --name "dev server"
cmux ssh user@remote -p 2222
cmux ssh user@remote -i ~/.ssh/id_ed25519`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <h2>{t("flagsTitle")}</h2>
      <table>
        <thead>
          <tr>
            <th>{t("flagName")}</th>
            <th>{t("flagDesc")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>--name</code></td><td>{t("flagNameVal")}</td></tr>
          <tr><td><code>-p, --port</code></td><td>{t("flagPort")}</td></tr>
          <tr><td><code>-i, --identity</code></td><td>{t("flagIdentity")}</td></tr>
          <tr><td><code>-o, --ssh-option</code></td><td>{t("flagSshOption")}</td></tr>
          <tr><td><code>--no-focus</code></td><td>{t("flagNoFocus")}</td></tr>
        </tbody>
      </table>

      <h2>SSH Sandboxes</h2>
      <p>
        Use cmux SSH to land inside Docker Sandboxes on the remote host. This keeps the
        normal cmux SSH workspace model, but starts the terminal inside Docker&apos;s
        shell sandbox instead of the host login shell.
      </p>
      <CodeBlock lang="bash">{`cmux ssh dev@macmini --docker-sandbox --docker-sandbox-workspace ~/src/cmux
cmux ssh dev@macmini --docker-sandbox --docker-sandbox-name cmux-dev
cmux ssh dev@macmini --docker-sandbox --docker-sandbox-workspace ~/src/cmux --docker-sandbox-mount ~/docs/cmux:ro
cmux ssh dev@macmini --docker-sandbox --docker-sandbox-workspace ~/src/cmux -- -lc "git status && exec bash -il"`}</CodeBlock>
      <p>
        cmux checks for <code>docker sandbox</code> on the remote host, creates writable
        workspace directories when needed, and then runs <code>docker sandbox run shell</code>
        for you. The primary workspace path becomes the main sandbox mount. Additional
        <code>--docker-sandbox-mount</code>
        paths are passed through directly, and args after <code>--</code> become shell
        args inside the sandbox.
      </p>
      <p>
        This targets Docker Desktop&apos;s built-in <code>docker sandbox</code> command on
        the remote host. Docker documents that integration as requiring Docker Desktop
        4.58 or later, and it also notes that the standalone <code>sbx</code> CLI is the
        fuller option. cmux surfaces a preflight error if the remote machine does not
        expose <code>docker sandbox</code>.
      </p>

      <h2>{t("browserTitle")}</h2>
      <p>{t("browserDesc")}</p>

      <h2>{t("dragDropTitle")}</h2>
      <p>{t("dragDropDesc")}</p>

      <h2>{t("notificationsTitle")}</h2>
      <p>{t("notificationsDesc")}</p>

      <h2>{t("agentsTitle")}</h2>
      <p>{t("agentsDesc")}</p>
      <CodeBlock lang="bash">{`# Inside an SSH session:
cmux claude-teams
cmux omo`}</CodeBlock>

      <h2>{t("reconnectTitle")}</h2>
      <p>{t("reconnectDesc")}</p>

      <h2>{t("daemonTitle")}</h2>
      <p>{t("daemonDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("daemonFeature")}</th>
            <th>{t("daemonHow")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>{t("daemonProxy")}</td><td>{t("daemonProxyHow")}</td></tr>
          <tr><td>{t("daemonRelay")}</td><td>{t("daemonRelayHow")}</td></tr>
          <tr><td>{t("daemonSession")}</td><td>{t("daemonSessionHow")}</td></tr>
        </tbody>
      </table>
      <p>{t("daemonPath")}</p>
    </>
  );
}
