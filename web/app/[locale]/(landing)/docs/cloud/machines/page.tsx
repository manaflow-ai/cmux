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
      <p>{t("createApp")}</p>
      <p>{t("createCli")}</p>
      <CodeBlock lang="bash">{`cmux vm new
cmux vm new --size 16g --name "search index"
cmux vm new --detach --json`}</CodeBlock>
      <p>{t("createFailed")}</p>

      <DocsHeading level={2} id="sizes">{t("sizesTitle")}</DocsHeading>
      <p>{t("sizesDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("sizeColumn")}</th>
            <th>{t("memoryColumn")}</th>
            <th>{t("cpuColumn")}</th>
            <th>{t("diskColumn")}</th>
            <th>{t("planColumn")}</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><code>4g</code></td><td>4 GB</td><td>2</td><td>16 GB</td><td>{t("planPaid")}</td></tr>
          <tr><td><code>8g</code></td><td>8 GB</td><td>4</td><td>32 GB</td><td>{t("planPaid")}</td></tr>
          <tr><td><code>16g</code></td><td>16 GB</td><td>8</td><td>64 GB</td><td>{t("planMax")}</td></tr>
          <tr><td><code>24g</code></td><td>24 GB</td><td>12</td><td>96 GB</td><td>{t("planMax")}</td></tr>
          <tr><td><code>32g</code></td><td>32 GB</td><td>16</td><td>128 GB</td><td>{t("planMax")}</td></tr>
        </tbody>
      </table>
      <p>{t("sizesDefault")}</p>

      <DocsHeading level={2} id="plan-limits">{t("limitsTitle")}</DocsHeading>
      <p>{t("limitsDesc")}</p>
      <ul>
        <li>{t("limitsFree")}</li>
        <li>{t("limitsPaid")}</li>
        <li>{t("limitsTeam")}</li>
        <li>{t("limitsMax")}</li>
        <li>{t("limitsOversize")}</li>
      </ul>
      <p>{t("limitsPricing")}</p>

      <DocsHeading level={2} id="agent-updates">{t("agentUpdatesTitle")}</DocsHeading>
      <p>{t("agentUpdatesDesc")}</p>
      <p>{t("agentUpdatesSource")}</p>
      <p>{t("agentUpdatesStatus")}</p>
      <CodeBlock lang="bash">{`cat /etc/cmux/agent-updates.state
tail /var/log/cmux-agent-updates.log`}</CodeBlock>
      <p>{t("agentUpdatesToggle")}</p>
      <CodeBlock lang="bash">{`cmux vm new --agent-updates latest
cmux vm agent-updates brave-otter
cmux vm agent-updates brave-otter image`}</CodeBlock>
      <p>{t("agentUpdatesNetwork")}</p>

      <DocsHeading level={2} id="resize">{t("resizeTitle")}</DocsHeading>
      <p>{t("resizeDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm resize brave-otter --memory 16G
cmux vm resize brave-otter --cpu 8 --disk 128G`}</CodeBlock>

      <DocsHeading level={2} id="pause-and-resume">{t("pauseTitle")}</DocsHeading>
      <p>{t("pauseDesc")}</p>
      <p>{t("pauseIdle")}</p>
      <CodeBlock lang="bash">{`cmux vm pause brave-otter
cmux vm resume brave-otter
cmux vm wait brave-otter --wake --timeout 180`}</CodeBlock>
      <p>{t("waitDesc")}</p>

      <DocsHeading level={2} id="checkpoints-and-forks">{t("snapshotsTitle")}</DocsHeading>
      <p>{t("snapshotsDesc")}</p>
      <p>{t("snapshotsUse")}</p>
      <CodeBlock lang="bash">{`cmux vm checkpoint brave-otter --name before-migration
cmux vm snapshot ls brave-otter
cmux vm restore <snapshot-id>
cmux vm fork brave-otter --name try-b
cmux vm snapshot rm brave-otter <snapshot-id>`}</CodeBlock>
      <p>{t("snapshotsCapability")}</p>

      <DocsHeading level={2} id="rename">{t("renameTitle")}</DocsHeading>
      <p>{t("renameDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm rename brave-otter "billing api"
cmux vm rename brave-otter --clear`}</CodeBlock>

      <DocsHeading level={2} id="status">{t("statusTitle")}</DocsHeading>
      <p>{t("statusDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm status brave-otter
cmux vm stats brave-otter`}</CodeBlock>

      <DocsHeading level={2} id="delete">{t("deleteTitle")}</DocsHeading>
      <p>{t("deleteDesc")}</p>
      <p>{t("deleteCheckpoint")}</p>
      <CodeBlock lang="bash">{`cmux vm rm brave-otter`}</CodeBlock>

      <DocsHeading level={2} id="when-your-plan-ends">{t("accessTitle")}</DocsHeading>
      <p>{t("accessDesc")}</p>
    </>
  );
}
