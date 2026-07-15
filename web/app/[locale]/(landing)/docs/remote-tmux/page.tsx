import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { remoteTmuxDocsLocales } from "@/i18n/locale-availability";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

function assertSupportedLocale(locale: string) {
  if (
    !remoteTmuxDocsLocales.includes(
      locale as (typeof remoteTmuxDocsLocales)[number],
    )
  ) {
    notFound();
  }
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  return auditedDocsMetadata({
    locale,
    pageKey: "remoteTmux",
    path: "/docs/remote-tmux",
    availableLocales: remoteTmuxDocsLocales,
  });
}

export default async function RemoteTmuxPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.remoteTmux" });

  return (
    <>
      <DocsSchema namespace="docs.remoteTmux" path="/docs/remote-tmux" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <Callout>{t("betaNote")}</Callout>

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

      <DocsHeading level={2} id="requirements">{t("requirementsTitle")}</DocsHeading>
      <p>{t("requirementsDesc")}</p>

      <DocsHeading level={2} id="enable">{t("enableTitle")}</DocsHeading>
      <p>{t("enableDesc")}</p>

      <DocsHeading level={2} id="attach">{t("attachTitle")}</DocsHeading>
      <p>{t("attachIntro")}</p>
      <p>{t("attachNewWindow")}</p>
      <p>{t("attachCli")}</p>
      <CodeBlock lang="bash">{`cmux ssh-tmux dev@example.com\ncmux ssh-tmux my-ssh-alias --port 2222 --identity ~/.ssh/id_ed25519\ncmux ssh-tmux dev@example.com --new-window`}</CodeBlock>
      <p>{t("attachSockets")}</p>

      <DocsHeading level={3} id="permission-denied">{t("troubleshootTitle")}</DocsHeading>
      <p>{t("troubleshootDesc")}</p>
      <CodeBlock lang="text">{`Host my-ssh-alias\n    HostName 203.0.113.10\n    User dev\n    IdentityFile ~/.ssh/id_ed25519`}</CodeBlock>
      <p>{t("troubleshootFallback")}</p>

      <DocsHeading level={2} id="how-it-works">{t("howTitle")}</DocsHeading>
      <p>{t("howDesc")}</p>

      <DocsHeading level={2} id="behavior">{t("behaviorTitle")}</DocsHeading>
      <ul>
        <li>{t("behaviorSize")}</li>
        <li>{t("behaviorSplit")}</li>
        <li>{t("behaviorReorder")}</li>
        <li>{t("behaviorCwd")}</li>
        <li>{t("behaviorPaste")}</li>
        <li>{t("behaviorMouse")}</li>
        <li>{t("behaviorUnicode")}</li>
      </ul>

      <DocsHeading level={2} id="socket-commands">{t("socketTitle")}</DocsHeading>
      <p>{t("socketDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("socketMethod")}</th>
            <th>{t("socketParams")}</th>
            <th>{t("socketMeaning")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>remote.tmux.sessions</code></td><td><code>host</code>, <code>port?</code>, <code>identity_file?</code></td><td>{t("methodSessions")}</td></tr>
          <tr><td><code>remote.tmux.attach</code></td><td><code>host</code>, <code>session</code>, <code>create?</code></td><td>{t("methodAttach")}</td></tr>
          <tr><td><code>remote.tmux.mirror</code></td><td><code>host</code>, <code>port?</code>, <code>identity_file?</code>, <code>activate?</code></td><td>{t("methodMirror")}</td></tr>
          <tr><td><code>remote.tmux.detach</code></td><td><code>host</code>, <code>session</code></td><td>{t("methodDetach")}</td></tr>
          <tr><td><code>remote.tmux.state</code></td><td><code>host</code>, <code>session</code></td><td>{t("methodState")}</td></tr>
        </tbody>
      </table>
      <p>{t("socketSafetyDesc")}</p>
      <CodeBlock lang="json">{`{ "method": "remote.tmux.mirror", "params": { "host": "dev.example.com" } }`}</CodeBlock>

      <DocsHeading level={2} id="limitations">{t("limitationsTitle")}</DocsHeading>
      <ul>
        <li>{t("limitReconnect")}</li>
        <li>{t("limitPaste")}</li>
        <li>{t("limitCwd")}</li>
        <li>{t("limitReflow")}</li>
      </ul>
    </>
  );
}
