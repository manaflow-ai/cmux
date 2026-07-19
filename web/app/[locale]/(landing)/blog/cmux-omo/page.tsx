import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { englishFallbackContentLocales } from "@/i18n/locale-availability";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxOmo" });
  const post = await getTranslations({ locale, namespace: "blog.posts.cmuxOmo" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(
    locale,
    "/blog/cmux-omo",
    englishFallbackContentLocales,
  );
  const { title, description } = blogPostSeoCopy(locale, "cmuxOmo", t, post, siteMeta);
  return {
    title: { absolute: title },
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-03-30T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmuxOmoPage() {
  const t = useTranslations("blog.posts.cmuxOmo");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="cmuxOmo" seoKey="cmuxOmo" path="/blog/cmux-omo" datePublished="2026-03-30T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-03-30" className="text-sm text-muted">
        {t("date")}
      </time>

      <video
        src="/blog/cmux-omo-demo.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="mt-6 rounded-lg w-full h-auto"
      />

      <p className="mt-6">
        {t.rich("p1", {
          code: (chunks) => <code>{chunks}</code>,
          claudeTeamsLink: (chunks) => (
            <Link href="/docs/agent-integrations/claude-code-teams">{chunks}</Link>
          ),
        })}
      </p>
      <p>
        {t.rich("p2", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <p className="mt-4">
        <Link href="/docs/agent-integrations/oh-my-opencode">Read the docs &rarr;</Link>
      </p>
    </>
  );
}
