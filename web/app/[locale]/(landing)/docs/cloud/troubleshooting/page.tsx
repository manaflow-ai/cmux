import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudTroubleshooting",
    path: "/docs/cloud/troubleshooting",
  });
}

import { CodeBlock } from "@/app/[locale]/components/code-block";

export default async function CloudTroubleshootingPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudTroubleshooting" });

  return (
    <>
      <DocsSchema namespace="docs.cloudTroubleshooting" path="/docs/cloud/troubleshooting" />
      <DocsHeading level={1} id="title">{t("nextTitle")}</DocsHeading>
      <p>{t("nextIntro")}</p>
      <table>
        <thead><tr><th>{t("nextSymptom")}</th><th>{t("nextFix")}</th></tr></thead>
        <tbody>
          <tr><td><code>{"new-machine: pending: true"}</code></td><td>{t("nextPendingFix")}</td></tr>
          <tr><td><code>{"No Cloud machine is selected. Right-click a machine or pass --target machine:<id>"}</code></td><td>{t("nextTargetFix")}</td></tr>
          <tr><td><code>{"cmux cloud open-machine is not a CLI verb; run it with: cmux action run cloudOpenMachine"}</code></td><td>{t("nextOpenFix")}</td></tr>
          <tr><td><code>{"start-session: cannot hold agent chat tabs yet: update it"}</code></td><td>{t("nextAgentFix")}</td></tr>
          <tr><td><code>{"open-browser: its cmux is too old"}</code></td><td>{t("nextBrowserFix")}</td></tr>
          <tr><td><code>{"port-list / port-forward: uses the classic Cloud link, which keeps no port forwards on this Mac"}</code></td><td>{t("nextPortFix")}</td></tr>
          <tr><td><code>{"fork-machine: This action is unavailable for this Cloud machine."}</code></td><td>{t("nextForkFix")}</td></tr>
          <tr><td><code>{"set-idle-pause: cmux Cloud does not pause idle machines yet"}</code></td><td>{t("nextIdleFix")}</td></tr>
          <tr><td><code>{"This machine has no finished machine config yet. Run cmux cloud apply-machine-config first"}</code></td><td>{t("nextSecretsFix")}</td></tr>
          <tr><td><code>{"setup-github: gh_status: failed, ok: false"}</code></td><td>{t("nextGithubFix")}</td></tr>
          <tr><td><code>{"exec: 25 s"}</code></td><td>{t("nextExecFix")}</td></tr>
        </tbody>
      </table>
      <CodeBlock lang="bash">{`cmux cloud list-machines
cmux cloud new-terminal-on-machine --target 'machine:<id>' --focus
cmux cloud machine-link --target 'machine:<id>' --port 3000
cmux cloud pause-machine --target 'machine:<id>'
cmux cloud resume-machine --target 'machine:<id>'`}</CodeBlock>

      <DocsHeading level={2} id="get-help">{t("nextSupport")}</DocsHeading>
      <p>{t("nextSupportBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud diagnostics`}</CodeBlock>
    </>
  );
}
