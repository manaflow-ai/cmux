import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { Link } from "../../../../i18n/navigation";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.vault" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/vault"),
  };
}

export default function VaultPage() {
  const t = useTranslations("docs.vault");

  return (
    <>
      <DocsSchema namespace="docs.vault" path="/docs/vault" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="what-it-indexes">{t("indexesTitle")}</DocsHeading>
      <p>{t("indexesDesc")}</p>
      <ul>
        <li>{t("indexCodex")}</li>
        <li>{t("indexClaude")}</li>
        <li>{t("indexOpenCode")}</li>
        <li>{t("indexPi")}</li>
      </ul>

      <DocsHeading level={2} id="workflow">{t("workflowTitle")}</DocsHeading>
      <ol>
        <li>{t("workflowOpen")}</li>
        <li>{t("workflowSearch")}</li>
        <li>{t("workflowDrag")}</li>
        <li>{t("workflowContinue")}</li>
      </ol>

      <DocsHeading level={2} id="when-to-use">{t("useTitle")}</DocsHeading>
      <p>{t("useDesc")}</p>

      <DocsHeading level={2} id="limits">{t("limitsTitle")}</DocsHeading>
      <p>{t("limitsDesc")}</p>

      <p className="mt-6">
        {t.rich("blogCta", {
          link: (chunks) => <Link href="/blog/cmux-vault">{chunks}</Link>,
        })}
      </p>
    </>
  );
}

