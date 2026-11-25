import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudCli",
    path: "/docs/cloud/cli",
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CloudCliPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudCli" });

  return (
    <>
      <DocsSchema namespace="docs.cloudCli" path="/docs/cloud/cli" />
      <DocsHeading level={1} id="title">{t("nextTitle")}</DocsHeading>
      <p>{t("nextIntro")}</p>
      <p>{t("nextTargets", { machineTarget: "machine:<id>" })}</p>
      <CodeBlock lang="bash">{`cmux cloud list-machines
cmux cloud machine-status --target 'machine:<id>'
cmux cloud new-machine --help
cmux action describe newCloudMachine`}</CodeBlock>

      <DocsHeading level={2} id="actions">{t("nextCatalog")}</DocsHeading>
      <p>{t("nextCatalogBody")}</p>
      <table>
        <thead><tr><th>{t("nextCommand")}</th><th>{t("nextAction")}</th></tr></thead>
        <tbody>
          {/* GENERATED_CLOUD_ACTIONS_START */}
          <tr><td><code>cmux cloud apply-machine-config</code></td><td><code>cloudApplyMachineConfig</code></td></tr>
          <tr><td><code>cmux cloud bring-back</code></td><td><code>cloudBringBack</code></td></tr>
          <tr><td><code>cmux cloud delete-snapshot</code></td><td><code>palette.cloud.deleteSnapshot</code></td></tr>
          <tr><td><code>cmux cloud deliver-secrets</code></td><td><code>cloudDeliverSecrets</code></td></tr>
          <tr><td><code>cmux cloud diagnostics</code></td><td><code>cloudDiagnostics</code></td></tr>
          <tr><td><code>cmux cloud domain-list</code></td><td><code>cloudDomainList</code></td></tr>
          <tr><td><code>cmux cloud enroll-machine</code></td><td><code>cloudEnrollMachine</code></td></tr>
          <tr><td><code>cmux cloud exec</code></td><td><code>cloudExec</code></td></tr>
          <tr><td><code>cmux cloud file-mkdir</code></td><td><code>cloudFileMkdir</code></td></tr>
          <tr><td><code>cmux cloud file-read</code></td><td><code>cloudFileRead</code></td></tr>
          <tr><td><code>cmux cloud file-remove</code></td><td><code>cloudFileRemove</code></td></tr>
          <tr><td><code>cmux cloud file-stat</code></td><td><code>cloudFileStat</code></td></tr>
          <tr><td><code>cmux cloud file-write</code></td><td><code>cloudFileWrite</code></td></tr>
          <tr><td><code>cmux cloud files-list</code></td><td><code>cloudFilesList</code></td></tr>
          <tr><td><code>cmux cloud firewall-create</code></td><td><code>cloudFirewallCreate</code></td></tr>
          <tr><td><code>cmux cloud firewall-delete</code></td><td><code>cloudFirewallDelete</code></td></tr>
          <tr><td><code>cmux cloud firewall-get</code></td><td><code>cloudFirewallGet</code></td></tr>
          <tr><td><code>cmux cloud firewall-list</code></td><td><code>cloudFirewallList</code></td></tr>
          <tr><td><code>cmux cloud fork-machine</code></td><td><code>palette.cloud.fork</code></td></tr>
          <tr><td><code>cmux cloud hand-off-machine</code></td><td><code>palette.cloud.handoff</code></td></tr>
          <tr><td><code>cmux cloud kill-machine</code></td><td><code>cloudKillMachine</code></td></tr>
          <tr><td><code>cmux cloud list-machines</code></td><td><code>cloudListMachines</code></td></tr>
          <tr><td><code>cmux cloud machine-link</code></td><td><code>cloudMachineLink</code></td></tr>
          <tr><td><code>cmux cloud machine-ports</code></td><td><code>palette.cloud.ports</code></td></tr>
          <tr><td><code>cmux cloud machine-status</code></td><td><code>palette.cloud.status</code></td></tr>
          <tr><td><code>cmux cloud move</code></td><td><code>cloudMove</code></td></tr>
          <tr><td><code>cmux cloud network-list</code></td><td><code>cloudNetworkList</code></td></tr>
          <tr><td><code>cmux cloud new-machine</code></td><td><code>newCloudMachine</code></td></tr>
          <tr><td><code>cmux cloud new-terminal-on-machine</code></td><td><code>cloudNewTerminal</code></td></tr>
          <tr><td><code>cmux cloud new-workspace</code></td><td><code>newCloudWorkspace</code></td></tr>
          <tr><td><code>cmux cloud open-browser</code></td><td><code>cloudOpenBrowser</code></td></tr>
          <tr><td><code>cmux cloud open-desktop</code></td><td><code>cloudOpenDesktop</code></td></tr>
          <tr><td><code>cmux cloud open-mobile-pairing</code></td><td><code>palette.mobileConnect</code></td></tr>
          <tr><td><code>cmux cloud pause-machine</code></td><td><code>cloudPauseMachine</code></td></tr>
          <tr><td><code>cmux cloud port-close</code></td><td><code>cloudPortClose</code></td></tr>
          <tr><td><code>cmux cloud port-forward</code></td><td><code>cloudPortForward</code></td></tr>
          <tr><td><code>cmux cloud port-list</code></td><td><code>cloudPortList</code></td></tr>
          <tr><td><code>cmux cloud prepare-scp</code></td><td><code>cloudPrepareSCP</code></td></tr>
          <tr><td><code>cmux cloud promote-machine-to-template</code></td><td><code>palette.cloud.promoteTemplate</code></td></tr>
          <tr><td><code>cmux cloud publication-list</code></td><td><code>cloudPublicationList</code></td></tr>
          <tr><td><code>cmux cloud rename-machine</code></td><td><code>cloudRenameMachine</code></td></tr>
          <tr><td><code>cmux cloud resize-machine</code></td><td><code>cloudResizeMachine</code></td></tr>
          <tr><td><code>cmux cloud restore-machine</code></td><td><code>palette.cloud.restore</code></td></tr>
          <tr><td><code>cmux cloud resume-machine</code></td><td><code>cloudResumeMachine</code></td></tr>
          <tr><td><code>cmux cloud set-idle-pause</code></td><td><code>cloudSetIdlePause</code></td></tr>
          <tr><td><code>cmux cloud setup-github</code></td><td><code>cloudSetupGitHub</code></td></tr>
          <tr><td><code>cmux cloud sign-in</code></td><td><code>palette.auth.signIn</code></td></tr>
          <tr><td><code>cmux cloud sign-out</code></td><td><code>palette.auth.signOut</code></td></tr>
          <tr><td><code>cmux cloud snapshot-machine</code></td><td><code>palette.cloud.snapshot</code></td></tr>
          <tr><td><code>cmux cloud ssh</code></td><td><code>cloudSSH</code></td></tr>
          <tr><td><code>cmux cloud start-session</code></td><td><code>cloudStartSession</code></td></tr>
          <tr><td><code>cmux cloud tunnel-attach</code></td><td><code>cloudTunnelAttach</code></td></tr>
          <tr><td><code>cmux cloud tunnel-detach</code></td><td><code>cloudTunnelDetach</code></td></tr>
          <tr><td><code>cmux cloud tunnel-rotate-key</code></td><td><code>cloudTunnelRotateKey</code></td></tr>
          {/* GENERATED_CLOUD_ACTIONS_END */}
        </tbody>
      </table>

      <DocsHeading level={2} id="secrets">{t("nextSecrets")}</DocsHeading>
      <p>{t("nextSecretsBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud secret set NAME
cmux cloud secret set NAME --repo OWNER/NAME
cmux cloud secret ls
cmux cloud secret rm NAME
cmux cloud secret rm NAME --repo OWNER/NAME`}</CodeBlock>

      <DocsHeading level={2} id="hand-off">{t("nextHandoff")}</DocsHeading>
      <p>{t("nextHandoffBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud hand-off-machine --target 'machine:<id>'`}</CodeBlock>
      <p><Link href="/docs/cloud" className={linkClass}>{t("nextHelp")}</Link></p>
      <p><Link href="/docs/cloud/troubleshooting" className={linkClass}>{t("nextHelp")}</Link></p>
    </>
  );
}
