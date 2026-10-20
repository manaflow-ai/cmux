import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { BlogPostMeta } from "@/app/[locale]/components/blog-author";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { fallbackContentLocales } from "@/i18n/locale-availability";
import { Link } from "@/i18n/navigation";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";

const path = "/blog/367-billion-tokens";
const publishedTime = "2026-07-29T00:00:00Z";
const videoUrl = "https://www.youtube.com/watch?v=YOst-qdMW0o";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({
    locale,
    namespace: "blog.tokenMultitasking",
  });
  const post = await getTranslations({
    locale,
    namespace: "blog.posts.tokenMultitasking",
  });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter(
        (keyword): keyword is string => typeof keyword === "string",
      )
    : [];
  const alternates = buildAlternates(
    locale,
    path,
    fallbackContentLocales,
  );
  const { title, description } = blogPostSeoCopy(
    locale,
    "tokenMultitasking",
    t,
    post,
    siteMeta,
  );

  return {
    title: { absolute: title },
    description,
    keywords,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime,
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function TokenMultitaskingPage() {
  const t = useTranslations("blog.posts.tokenMultitasking");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema
        postKey="tokenMultitasking"
        seoKey="tokenMultitasking"
        path={path}
        datePublished={publishedTime}
      />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <BlogPostMeta date={t("date")} dateTime="2026-07-29" />

      <p className="mt-6">{t("p1")}</p>

      <iframe
        className="my-6 rounded-lg w-full aspect-video"
        src="https://www.youtube.com/embed/YOst-qdMW0o"
        title={t("videoTitle")}
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
        referrerPolicy="strict-origin-when-cross-origin"
        loading="lazy"
        allowFullScreen
      />

      <p className="text-sm text-muted">
        {t.rich("watchVideo", {
          link: (chunks) => <a href={videoUrl}>{chunks}</a>,
        })}
      </p>

      <h2>{t("workflowTitle")}</h2>
      <p>{t("workflowIntro")}</p>
      <ol>
        <li>
          {t.rich("workflowJump", {
            shortcut: (chunks) => (
              <Link href="/blog/cmd-shift-u">{chunks}</Link>
            ),
          })}
        </li>
        <li>{t("workflowReview")}</li>
        <li>{t("workflowRepeat")}</li>
        <li>{t("workflowStart")}</li>
      </ol>
      <p>{t("workflowClose")}</p>

      <h2>{t("simpleTitle")}</h2>
      <p>{t("simpleP1")}</p>
      <p>
        {t.rich("simpleP2", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("economicsTitle")}</h2>
      <p>
        {t.rich("economicsP1", {
          codexBar: (chunks) => (
            <a href="https://codexbar.app/">{chunks}</a>
          ),
        })}
      </p>
      <p>
        {t.rich("economicsP2", {
          coderouter: (chunks) => (
            <Link href="/dashboard/coderouter">{chunks}</Link>
          ),
        })}
      </p>
      <p>{t("closing")}</p>
    </>
  );
}
