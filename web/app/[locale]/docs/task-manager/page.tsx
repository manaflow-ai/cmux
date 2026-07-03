import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.taskManager" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/task-manager"),
  };
}

export default function TaskManagerDocsPage() {
  const t = useTranslations("docs.taskManager");

  return (
    <>
      <DocsSchema namespace="docs.taskManager" path="/docs/task-manager" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="open">{t("openTitle")}</DocsHeading>
      <p>{t("openDesc")}</p>
      <CodeBlock lang="bash">{`cmux top`}</CodeBlock>
      <p>{t("paletteDesc")}</p>

      <DocsHeading level={2} id="what-it-shows">{t("showsTitle")}</DocsHeading>
      <ul>
        <li>{t("showsWindows")}</li>
        <li>{t("showsWorkspaces")}</li>
        <li>{t("showsAgents")}</li>
        <li>{t("showsBrowsers")}</li>
      </ul>

      <DocsHeading level={2} id="workflow">{t("workflowTitle")}</DocsHeading>
      <ol>
        <li>{t("workflowOpen")}</li>
        <li>{t("workflowSort")}</li>
        <li>{t("workflowJump")}</li>
        <li>{t("workflowFix")}</li>
      </ol>

      <DocsHeading level={2} id="when-to-use">{t("useTitle")}</DocsHeading>
      <p>{t("useDesc")}</p>

      <p className="mt-6">
        {t.rich("blogCta", {
          link: (chunks) => <Link href="/blog/task-manager">{chunks}</Link>,
        })}
      </p>
    </>
  );
}

