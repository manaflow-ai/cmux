import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.sessionRestore" });
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
      publishedTime: "2026-05-13T00:00:00Z",
      modifiedTime: "2026-07-03T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/session-restore"),
  };
}

export default function SessionRestoreBlogPage() {
  const t = useTranslations("blog.posts.sessionRestore");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="sessionRestore" path="/blog/session-restore" datePublished="2026-05-13T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-05-13" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>
      <p>{t("p2")}</p>
      <p>{t("seoP")}</p>

      <h2>{t("baselineTitle")}</h2>
      <p>{t("baselineP")}</p>
      <ul>
        <li>{t("baselineItemLayout")}</li>
        <li>{t("baselineItemCwd")}</li>
        <li>{t("baselineItemScrollback")}</li>
        <li>{t("baselineItemBrowser")}</li>
      </ul>

      <h2>{t("agentTitle")}</h2>
      <p>
        {t.rich("agentP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock lang="bash">{`cmux hooks setup`}</CodeBlock>
      <p>{t("agentP2")}</p>

      <h2>{t("implementationTitle")}</h2>
      <p>{t("implementationP1")}</p>
      <p>{t("implementationP2")}</p>

      <h2>{t("limitsTitle")}</h2>
      <p>{t("limitsP")}</p>

      <h2>{t("workflowTitle")}</h2>
      <ol>
        <li>{t("workflowInstall")}</li>
        <li>{t("workflowWork")}</li>
        <li>{t("workflowRelaunch")}</li>
        <li>{t("workflowVerify")}</li>
      </ol>

      <h2>{t("faqTitle")}</h2>
      <h3>{t("faqCrashTitle")}</h3>
      <p>{t("faqCrashBody")}</p>
      <h3>{t("faqTmuxTitle")}</h3>
      <p>{t("faqTmuxBody")}</p>

      <p className="mt-6">
        {t.rich("docsCta", {
          link: (chunks) => <Link href="/docs/session-restore">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
