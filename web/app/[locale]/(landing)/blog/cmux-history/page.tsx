import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { cmuxHistorySeoCopy } from "@/i18n/audited-seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";
import { CodeBlock } from "@/app/[locale]/components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxHistory" });
  const post = await getTranslations({
    locale,
    namespace: "blog.posts.cmuxHistory",
  });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/blog/cmux-history");
  const { title, description } = cmuxHistorySeoCopy(
    locale,
    t,
    post,
    siteMeta,
  );
  return {
    title: { absolute: title },
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-06-02T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmuxHistoryBlogPage() {
  const t = useTranslations("blog.posts.cmuxHistory");
  const tm = useTranslations("blog.cmuxHistory");
  const siteMeta = useTranslations("meta");
  const tc = useTranslations("common");
  const locale = useLocale();
  const seoCopy = cmuxHistorySeoCopy(locale, tm, t, siteMeta);

  return (
    <>
      <BlogSchema
        postKey="cmuxHistory"
        path="/blog/cmux-history"
        datePublished="2026-06-02T00:00:00Z"
        headline={seoCopy.title}
        description={seoCopy.description}
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
      <time dateTime="2026-06-02" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>

      <video
        src="/blog/cmux-history.mp4"
        width={1280}
        height={990}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <h2>{t("reopenTitle")}</h2>
      <p>
        {t.rich("reopenP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("agentTitle")}</h2>
      <p>
        {t.rich("agentP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock lang="bash">{`cmux hooks setup`}</CodeBlock>
      <p>
        {t.rich("agentP2", {
          link: (chunks) => <Link href="/blog/session-restore">{chunks}</Link>,
        })}
      </p>

      <h2>{t("focusTitle")}</h2>
      <p>
        {t.rich("focusP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("fullHistoryTitle")}</h2>
      <p>{t("fullHistoryP")}</p>

      <p className="mt-6">
        {t.rich("docsCta", {
          link: (chunks) => <Link href="/docs/keyboard-shortcuts">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
