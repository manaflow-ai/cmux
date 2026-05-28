import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";
import { DocsHeading } from "../../components/docs-heading";

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
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/RoR9pMOZWkk"
        title="cmux SSH demo"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />

      <DocsHeading level={2} id="usage">{t("usage")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux ssh user@remote
cmux ssh user@remote --name "dev server"
cmux ssh user@remote -p 2222
cmux ssh user@remote -i ~/.ssh/id_ed25519`}</CodeBlock>
      <p>{t("usageDesc")}</p>

      <DocsHeading level={2} id="flags-title">{t("flagsTitle")}</DocsHeading>
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

      <DocsHeading level={2} id="ssh-deep-links">{t("deepLinksTitle")}</DocsHeading>
      <p>{t("deepLinksDesc")}</p>
      <CodeBlock lang="text">{`cmux://ssh?host=dev.example.com
cmux://ssh?host=dev.example.com&user=alice&port=2222&title=GPU%20box
cmux://ssh?host=workspace123.vm-ssh.freestyle.sh&user=workspace123%2Csession-token
cmux://ssh?host=dev.example.com&host-key-policy=accept-new&no-focus=true`}</CodeBlock>
      <p>{t("deepLinksWebFallbackDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/deeplink/ssh?host=workspace123.vm-ssh.freestyle.sh&user=workspace123%2Csession-token&title=Freestyle`}</CodeBlock>
      <p>{t("deepLinksPromptRulesDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/deeplink/prompt?text=Review%20this%20branch
https://cmux.com/deeplink/rules?name=freestyle&text=Prefer%20commas,%20colons:%20and%20small%20PRs`}</CodeBlock>
      <p>{t("deepLinksIconDesc")}</p>
      <CodeBlock lang="text">{`https://cmux.com/cmux-icon.svg
https://cmux.com/logo.png`}</CodeBlock>
      <p>{t("deepLinksButtonDesc")}</p>
      <CodeBlock lang="tsx">{`const params = new URLSearchParams({
  host: "workspace123.vm-ssh.freestyle.sh",
  user: "workspace123,session-token",
  title: "Freestyle",
});

const href = "https://cmux.com/deeplink/ssh?" + params.toString();`}</CodeBlock>
      <table>
        <thead>
          <tr>
            <th>{t("deepLinkParam")}</th>
            <th>{t("deepLinkMeaning")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>host</code></td><td>{t("deepLinkHost")}</td></tr>
          <tr><td><code>user</code></td><td>{t("deepLinkUser")}</td></tr>
          <tr><td><code>port</code></td><td>{t("deepLinkPort")}</td></tr>
          <tr><td><code>title</code> / <code>name</code></td><td>{t("deepLinkTitle")}</td></tr>
          <tr><td><code>connect-timeout</code></td><td>{t("deepLinkConnectTimeout")}</td></tr>
          <tr><td><code>server-alive-interval</code></td><td>{t("deepLinkServerAliveInterval")}</td></tr>
          <tr><td><code>server-alive-count-max</code></td><td>{t("deepLinkServerAliveCountMax")}</td></tr>
          <tr><td><code>host-key-policy</code></td><td>{t("deepLinkHostKeyPolicy")}</td></tr>
          <tr><td><code>no-focus</code></td><td>{t("deepLinkNoFocus")}</td></tr>
        </tbody>
      </table>
      <p>{t("deepLinksSchemeDesc")}</p>
      <p>{t("deepLinksSecurityDesc")}</p>

      <DocsHeading level={2} id="browser-title">{t("browserTitle")}</DocsHeading>
      <p>{t("browserDesc")}</p>

      <DocsHeading level={2} id="drag-drop-title">{t("dragDropTitle")}</DocsHeading>
      <p>{t("dragDropDesc")}</p>

      <DocsHeading level={2} id="notifications-title">{t("notificationsTitle")}</DocsHeading>
      <p>{t("notificationsDesc")}</p>

      <DocsHeading level={2} id="agents-title">{t("agentsTitle")}</DocsHeading>
      <p>{t("agentsDesc")}</p>
      <CodeBlock lang="bash">{`# Inside an SSH session:
cmux claude-teams
cmux omo`}</CodeBlock>

      <DocsHeading level={2} id="reconnect-title">{t("reconnectTitle")}</DocsHeading>
      <p>{t("reconnectDesc")}</p>

      <DocsHeading level={2} id="daemon-title">{t("daemonTitle")}</DocsHeading>
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
