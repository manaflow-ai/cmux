import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../../audited-docs-metadata";
import { DocsSchema } from "../../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudMachines",
    path: "/docs/cloud/machines",
  });
}

export default async function CloudMachinesPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudMachines" });

  return (
    <>
      <DocsSchema namespace="docs.cloudMachines" path="/docs/cloud/machines" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="create">{t("createTitle")}</DocsHeading>
      <p>{t("createCli")}</p>
      <CodeBlock lang="bash">{`cmux cloud new-machine
cmux cloud new-machine --size large --name search-index
cmux cloud new-machine --persistent --size medium
cmux cloud list-machines`}</CodeBlock>

      <DocsHeading level={2} id="sizes">{t("sizesTitle")}</DocsHeading>
      <p>{t("sizesDesc")}</p>
      <table>
        <thead><tr><th>{t("sizeColumn")}</th><th>{t("memoryColumn")}</th><th>{t("cpuColumn")}</th></tr></thead>
        <tbody>
          <tr><td><code>small</code></td><td>4 GB</td><td>2</td></tr>
          <tr><td><code>medium</code></td><td>8 GB</td><td>4</td></tr>
          <tr><td><code>large</code></td><td>16 GB</td><td>8</td></tr>
          <tr><td><code>xlarge</code></td><td>24 GB</td><td>12</td></tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="resize">{t("resizeTitle")}</DocsHeading>
      <p>{t("resizeDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud resize-machine --target 'machine:<id>' --size large`}</CodeBlock>

      <DocsHeading level={2} id="pause-and-resume">{t("pauseTitle")}</DocsHeading>
      <p>{t("pauseDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud pause-machine --target 'machine:<id>'
cmux cloud resume-machine --target 'machine:<id>'
cmux cloud set-idle-pause --target 'machine:<id>' --minutes off
cmux cloud set-idle-pause --target 'machine:<id>' --minutes 30`}</CodeBlock>

      <DocsHeading level={2} id="checkpoints-and-forks">{t("snapshotsTitle")}</DocsHeading>
      <p>{t("snapshotsDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud snapshot-machine --target 'machine:<id>'
cmux cloud restore-machine --target 'machine:<id>' --snapshot '<snapshot-id>'
cmux cloud fork-machine --target 'machine:<id>'
cmux cloud delete-snapshot --target 'machine:<id>' --snapshot '<snapshot-id>' --confirm`}</CodeBlock>
      <p>{t("snapshotsCapability")}</p>

      <DocsHeading level={2} id="rename">{t("renameTitle")}</DocsHeading>
      <p>{t("renameDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud rename-machine --target 'machine:<id>' --name "billing api"
cmux cloud rename-machine --target 'machine:<id>' --name ""`}</CodeBlock>

      <DocsHeading level={2} id="status">{t("statusTitle")}</DocsHeading>
      <p>{t("statusDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud list-machines
cmux cloud machine-status --target 'machine:<id>'`}</CodeBlock>

      <DocsHeading level={2} id="delete">{t("deleteTitle")}</DocsHeading>
      <p>{t("deleteDesc")}</p>
      <CodeBlock lang="bash">{`cmux cloud kill-machine --target 'machine:<id>' --confirm`}</CodeBlock>

    </>
  );
}
