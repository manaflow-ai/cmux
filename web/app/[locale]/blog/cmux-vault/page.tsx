import { getTranslations } from "next-intl/server";
import { hasFeatureWorkflowContent } from "../../../../i18n/locale-availability";
import { buildAlternates } from "../../../../i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxVault" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords,
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-05-22T00:00:00Z",
      modifiedTime: "2026-07-03T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-vault"),
  };
}

export default async function CmuxVaultPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const showFeatureWorkflow = hasFeatureWorkflowContent(locale);
  const t = await getTranslations({ locale, namespace: "blog.posts.cmuxVault" });
  const tc = await getTranslations({ locale, namespace: "common" });

  return (
    <>
      <BlogSchema postKey="cmuxVault" path="/blog/cmux-vault" datePublished="2026-05-22T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-05-22" className="text-sm text-muted">
        {t("date")}
      </time>

      <video
        src="/blog/cmux-vault.mp4"
        width={1280}
        height={902}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p>{t("p1")}</p>
      <p>{t("p2")}</p>
      <p>{t("p3")}</p>
      <p>{t("p4")}</p>

      {showFeatureWorkflow ? (
        <>
          <h2>{t("workflowTitle")}</h2>
          <ol>
            <li>{t("workflowOpen")}</li>
            <li>{t("workflowSearch")}</li>
            <li>{t("workflowDrag")}</li>
            <li>{t("workflowContinue")}</li>
          </ol>

          <h2>{t("useTitle")}</h2>
          <p>{t("useP")}</p>

          <h2>{t("faqTitle")}</h2>
          <h3>{t("faqAgentsTitle")}</h3>
          <p>{t("faqAgentsBody")}</p>
          <h3>{t("faqRestoreTitle")}</h3>
          <p>{t("faqRestoreBody")}</p>

          <p className="mt-6">
            {t.rich("docsCta", {
              link: (chunks) => <Link href="/docs/vault">{chunks}</Link>,
            })}
          </p>
        </>
      ) : null}
    </>
  );
}
