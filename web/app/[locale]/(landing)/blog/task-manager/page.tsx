import { getTranslations } from "next-intl/server";
import { hasFeatureWorkflowContent } from "@/i18n/locale-availability";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";
import { CodeBlock } from "@/app/[locale]/components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.taskManager" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  const alternates = buildAlternates(locale, "/blog/task-manager");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    keywords,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-05-22T00:00:00Z",
      modifiedTime: "2026-07-03T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default async function TaskManagerPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const showFeatureWorkflow = hasFeatureWorkflowContent(locale);
  const t = await getTranslations({ locale, namespace: "blog.posts.taskManager" });
  const tc = await getTranslations({ locale, namespace: "common" });

  return (
    <>
      <BlogSchema postKey="taskManager" path="/blog/task-manager" datePublished="2026-05-22T00:00:00Z" />
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

      <p className="mt-6">{t("p1")}</p>
      <p>{t("p2")}</p>
      <CodeBlock lang="bash">{`cmux top`}</CodeBlock>
      <p>{t("p3")}</p>
      <p>{t("p4")}</p>

      {showFeatureWorkflow ? (
        <>
          <h2>{t("workflowTitle")}</h2>
          <ol>
            <li>{t("workflowOpen")}</li>
            <li>{t("workflowScan")}</li>
            <li>{t("workflowJump")}</li>
            <li>{t("workflowAct")}</li>
          </ol>

          <h2>{t("useTitle")}</h2>
          <p>{t("useP")}</p>

          <h2>{t("faqTitle")}</h2>
          <h3>{t("faqAgentsTitle")}</h3>
          <p>{t("faqAgentsBody")}</p>
          <h3>{t("faqCliTitle")}</h3>
          <p>{t("faqCliBody")}</p>

          <p className="mt-6">
            {t.rich("docsCta", {
              link: (chunks) => <Link href="/docs/task-manager">{chunks}</Link>,
            })}
          </p>
        </>
      ) : null}
    </>
  );
}
