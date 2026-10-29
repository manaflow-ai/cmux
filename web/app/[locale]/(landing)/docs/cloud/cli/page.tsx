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

import catalog from "./actions.json";

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
          {catalog.actions.map(({ command, id }) => (
            <tr key={id}><td><code>{command}</code></td><td><code>{id}</code></td></tr>
          ))}
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
