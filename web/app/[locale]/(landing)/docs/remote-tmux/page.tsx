import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { remoteTmuxDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

type RemoteTmuxLocale = (typeof remoteTmuxDocsLocales)[number];

async function localeOr404(params: Promise<{ locale: string }>): Promise<RemoteTmuxLocale> {
  const { locale } = await params;
  if (!(remoteTmuxDocsLocales as readonly string[]).includes(locale)) notFound();
  return locale as RemoteTmuxLocale;
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const locale = await localeOr404(params);
  return auditedDocsMetadata({
    locale,
    pageKey: "remoteTmux",
    path: "/docs/remote-tmux",
    availableLocales: remoteTmuxDocsLocales,
  });
}

export default async function RemoteTmuxPage({ params }: { params: Promise<{ locale: string }> }) {
  const locale = await localeOr404(params);
  const t = await getTranslations({ locale, namespace: "docs.remoteTmux" });

  return (
    <>
      <DocsSchema namespace="docs.remoteTmux" path="/docs/remote-tmux" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <Callout>{t("betaNote")}</Callout>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="requirements">{t("requirementsTitle")}</DocsHeading>
      <p>{t("requirementsDesc")}</p>

      <DocsHeading level={2} id="enable">{t("enableTitle")}</DocsHeading>
      <p>{t("enableDesc")}</p>

      <DocsHeading level={2} id="attach">{t("attachTitle")}</DocsHeading>
      <p>{t("attachIntro")}</p>
      <CodeBlock lang="bash">{`# user@host, or any Host alias from ~/.ssh/config
cmux ssh-tmux build@devbox.internal

# non-default port and key
cmux ssh-tmux staging --port 2200 --identity ~/.ssh/staging_ed25519

# put the mirror in its own cmux window
cmux ssh-tmux build@devbox.internal --new-window`}</CodeBlock>
      <p>{t("attachCli")}</p>
      <p>{t("attachNewWindow")}</p>
      <Callout>{t("moshContrast")}</Callout>

      <DocsHeading level={3} id="permission-denied">{t("troubleshootTitle")}</DocsHeading>
      <p>{t("troubleshootDesc")}</p>
      <CodeBlock title="~/.ssh/config" lang="text">{`Host staging
  HostName 198.51.100.24
  Port 2200
  User deploy
  IdentityFile ~/.ssh/staging_ed25519`}</CodeBlock>
      <p>{t("troubleshootFallback")}</p>

      <DocsHeading level={2} id="mapping">{t("mappingTitle")}</DocsHeading>
      <p>{t("mappingIntro")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("mapTmux")}</th>
            <th>{t("mapCmux")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>session</code></td><td>{t("rowSession")}</td></tr>
          <tr><td><code>window</code></td><td>{t("rowWindow")}</td></tr>
          <tr><td><code>pane</code></td><td>{t("rowPane")}</td></tr>
        </tbody>
      </table>
      <p>{t("mappingPanes")}</p>

      <DocsHeading level={2} id="behavior">{t("behaviorTitle")}</DocsHeading>
      <ul>
        <li>{t("behaviorSplit")}</li>
        <li>{t("behaviorSize")}</li>
        <li>{t("behaviorMouse")}</li>
        <li>{t("behaviorPaste")}</li>
        <li>{t("behaviorUnicode")}</li>
        <li>{t("behaviorCwd")}</li>
        <li>{t("behaviorReorder")}</li>
      </ul>

      <DocsHeading level={2} id="how-it-works">{t("howTitle")}</DocsHeading>
      <p>{t("howDesc")}</p>

      <DocsHeading level={2} id="socket-commands">{t("socketTitle")}</DocsHeading>
      <p>{t("socketDesc")}</p>
      <p>{t("attachSockets")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("socketMethod")}</th>
            <th>{t("socketParams")}</th>
            <th>{t("socketMeaning")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>remote.tmux.mirror</code></td>
            <td><code>host</code>, <code>port?</code>, <code>identity_file?</code>, <code>activate?</code></td>
            <td>{t("methodMirror")}</td>
          </tr>
          <tr>
            <td><code>remote.tmux.sessions</code></td>
            <td><code>host</code>, <code>port?</code>, <code>identity_file?</code></td>
            <td>{t("methodSessions")}</td>
          </tr>
          <tr>
            <td><code>remote.tmux.attach</code></td>
            <td><code>host</code>, <code>session</code>, <code>create?</code></td>
            <td>{t("methodAttach")}</td>
          </tr>
          <tr>
            <td><code>remote.tmux.state</code></td>
            <td><code>host</code>, <code>session</code></td>
            <td>{t("methodState")}</td>
          </tr>
          <tr>
            <td><code>remote.tmux.detach</code></td>
            <td><code>host</code>, <code>session</code></td>
            <td>{t("methodDetach")}</td>
          </tr>
        </tbody>
      </table>
      <CodeBlock lang="json">{`{"method": "remote.tmux.sessions", "params": {"host": "staging"}}`}</CodeBlock>
      <p>{t("socketSafetyDesc")}</p>

      <DocsHeading level={2} id="limitations">{t("limitationsTitle")}</DocsHeading>
      <ul>
        <li>{t("limitReconnect")}</li>
        <li>{t("limitReflow")}</li>
        <li>{t("limitPaste")}</li>
        <li>{t("limitCwd")}</li>
      </ul>
    </>
  );
}
