import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "@/i18n/seo";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsSchema } from "../docs-schema";

const extensionReviewQueueUrl =
  "https://github.com/manaflow-ai/cmux/issues?q=is%3Aissue%20state%3Aopen%20label%3Aextension-submission";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.extensionsMarketplace" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/extensions-marketplace"),
  };
}

export default function ExtensionsMarketplaceDocsPage() {
  const t = useTranslations("docs.extensionsMarketplace");

  return (
    <>
      <DocsSchema
        namespace="docs.extensionsMarketplace"
        path="/docs/extensions-marketplace"
      />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="discovery">{t("discoveryTitle")}</DocsHeading>
      <p>{t("discoveryIntro")}</p>
      <CodeBlock title="manaflow-ai/awesome-cmux/extensions.json" lang="json">{`{
  "extensions": [
    { "repo": "owner/repo", "addedAt": "2026-07-07" }
  ]
}`}</CodeBlock>

      <DocsHeading level={2} id="submit">{t("submitTitle")}</DocsHeading>
      <p>{t("submitIntro")}</p>
      <CodeBlock lang="text">cmux extension submit owner/repo</CodeBlock>
      <p>{t("submitIssue")}</p>

      <DocsHeading level={2} id="maintainers">{t("maintainersTitle")}</DocsHeading>
      <p>{t("maintainersIntro")}</p>
      <p>
        <a href={extensionReviewQueueUrl} target="_blank" rel="noopener noreferrer">
          {t("maintainersReviewQueueAction")}
        </a>
      </p>

      <DocsHeading level={2} id="approval">{t("approvalTitle")}</DocsHeading>
      <p>{t("approvalIntro")}</p>
      <ul>
        <li>{t("approvalInstall")}</li>
        <li>{t("approvalReview")}</li>
        <li>{t("approvalDogfood")}</li>
        <li>{t("approvalMerge")}</li>
      </ul>

      <DocsHeading level={2} id="install-command">{t("installTitle")}</DocsHeading>
      <p>{t("installIntro")}</p>
      <CodeBlock lang="text">cmux extension install owner/repo</CodeBlock>
      <p>{t("installConsent")}</p>

      <DocsHeading level={2} id="takedowns">{t("takedownsTitle")}</DocsHeading>
      <p>{t("takedownsIntro")}</p>
      <CodeBlock lang="text">manaflow-ai/awesome-cmux/extensions.json</CodeBlock>
    </>
  );
}
