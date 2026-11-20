import { getTranslations } from "next-intl/server";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
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
      <DocsHeading level={1} id="title">{t("nextTitle")}</DocsHeading>
      <p>{t("nextIntro")}</p>

      <DocsHeading level={2} id="sign-in">{t("nextSignIn")}</DocsHeading>
      <p>{t("nextSignInBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud sign-in
cmux cloud list-machines`}</CodeBlock>

      <DocsHeading level={2} id="create">{t("nextCreate")}</DocsHeading>
      <p>{t("nextCreateBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud new-machine --name work --size medium
cmux cloud list-machines`}</CodeBlock>
      <p>{t("nextPending", { machineTarget: "machine:<id>" })}</p>

      <DocsHeading level={2} id="terminal">{t("nextTerminal")}</DocsHeading>
      <p>{t("nextTerminalBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud new-terminal-on-machine --target 'machine:<id>' --focus`}</CodeBlock>

      <DocsHeading level={2} id="desktop">{t("nextDesktop")}</DocsHeading>
      <p>{t("nextDesktopBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud open-desktop --target 'machine:<id>' --focus`}</CodeBlock>

      <DocsHeading level={2} id="pause-resume">{t("nextPause")}</DocsHeading>
      <p>{t("nextPauseBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud pause-machine --target 'machine:<id>'
cmux cloud resume-machine --target 'machine:<id>'`}</CodeBlock>

      <DocsHeading level={2} id="delete">{t("nextDelete")}</DocsHeading>
      <p>{t("nextDeleteBody")}</p>
      <CodeBlock lang="bash">{`cmux cloud kill-machine --target 'machine:<id>' --confirm
cmux cloud list-machines`}</CodeBlock>

      <ul>
        <li><Link href="/docs/cloud/cli" className={linkClass}>{t("nextReference")}</Link></li>
        <li><Link href="/docs/cloud/troubleshooting" className={linkClass}>{t("nextTroubleshooting")}</Link></li>
      </ul>
    </>
  );
}
