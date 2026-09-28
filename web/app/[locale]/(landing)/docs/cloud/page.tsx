import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { Callout } from "@/app/[locale]/components/callout";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsLink as Link } from "@/app/[locale]/components/docs-link";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "cloudOverview",
    path: "/docs/cloud",
  });
}

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

export default async function CloudOverviewPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.cloudOverview" });

  return (
    <>
      <DocsSchema namespace="docs.cloudOverview" path="/docs/cloud" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>
      <Callout>{t("betaNote")}</Callout>

      <DocsHeading level={2} id="what-is-a-machine">{t("whatTitle")}</DocsHeading>
      <p>{t("whatDesc")}</p>
      <p>{t("whatDaemon")}</p>
      <p>{t("whatManyWorkspaces")}</p>
      <p>{t("whatNames")}</p>

      <DocsHeading level={2} id="requirements">{t("requirementsTitle")}</DocsHeading>
      <ul>
        <li>{t("reqMac")}</li>
        <li>{t("reqPlan")} <Link href="/pricing" className={linkClass}>cmux.com/pricing</Link></li>
        <li>{t("reqBeta")}</li>
        <li>{t("reqNoVpn")}</li>
      </ul>

      <DocsHeading level={2} id="quickstart">{t("quickstartTitle")}</DocsHeading>
      <ol>
        <li>{t("stepSignIn")}</li>
        <li>{t("stepCreate")}</li>
        <li>{t("stepWorkspace")}</li>
        <li>{t("stepAgent")}</li>
      </ol>
      <p>{t("stepCli")}</p>
      <CodeBlock lang="bash">{`cmux auth login
cmux vm new --size 8g --name "api work"
cmux vm ls
cmux vm open brave-otter
cmux vm agent --agent claude --machine brave-otter --sync -- "fix the failing tests"`}</CodeBlock>

      <DocsHeading level={2} id="cloud-in-the-app">{t("appTitle")}</DocsHeading>
      <p>{t("appSidebar")}</p>
      <p>{t("appMenu")}</p>
      <p>{t("appShortcuts")}</p>
      <CodeBlock lang="json">{`{
  "shortcuts": {
    "bindings": {
      "newCloudMachine": "cmd+y",
      "newCloudWorkspace": "cmd+shift+y"
    }
  }
}`}</CodeBlock>

      <DocsHeading level={2} id="cloud-from-the-cli">{t("cliIntroTitle")}</DocsHeading>
      <p>{t("cliIntroDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm              # list machines
cmux vm --help
cmux vm new --help
cmux vm guide        # full Markdown guide
cmux vm ls --json`}</CodeBlock>

      <DocsHeading level={2} id="base-machine">{t("baseTitle")}</DocsHeading>
      <p>{t("baseDesc")}</p>
      <CodeBlock lang="bash">{`cmux vm base
cmux vm base reset --reason "start clean"`}</CodeBlock>

      <DocsHeading level={2} id="next-steps">{t("nextTitle")}</DocsHeading>
      <ul>
        <li><Link href="/docs/cloud/machines" className={linkClass}>{t("nextMachines")}</Link></li>
        <li><Link href="/docs/cloud/workspaces" className={linkClass}>{t("nextWorkspaces")}</Link></li>
        <li><Link href="/docs/cloud/networking" className={linkClass}>{t("nextNetworking")}</Link></li>
        <li><Link href="/docs/cloud/cli" className={linkClass}>{t("nextCli")}</Link></li>
        <li><Link href="/docs/cloud/troubleshooting" className={linkClass}>{t("nextTroubleshooting")}</Link></li>
      </ul>
    </>
  );
}
