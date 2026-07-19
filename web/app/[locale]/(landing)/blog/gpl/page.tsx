import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { englishFallbackContentLocales } from "@/i18n/locale-availability";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.gpl" });
  const post = await getTranslations({ locale, namespace: "blog.posts.gpl" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(
    locale,
    "/blog/gpl",
    englishFallbackContentLocales,
  );
  const { title, description } = blogPostSeoCopy(locale, "gpl", t, post, siteMeta);
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

export default function GplPage() {
  const t = useTranslations("blog.posts.gpl");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="gpl" seoKey="gpl" path="/blog/gpl" datePublished="2026-03-30T00:00:00Z" />
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

      <p className="mt-6">{t("p1")}</p>
    </>
  );
}
