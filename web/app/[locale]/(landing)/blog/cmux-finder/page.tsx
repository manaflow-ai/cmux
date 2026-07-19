import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxFinder" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  const alternates = buildAlternates(locale, "/blog/cmux-finder");
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
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmuxFinderPage() {
  const t = useTranslations("blog.posts.cmuxFinder");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="cmuxFinder" path="/blog/cmux-finder" datePublished="2026-05-22T00:00:00Z" />
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
        src="/blog/cmux-finder.mp4"
        width={1280}
        height={736}
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
      <p>{t("p5")}</p>
    </>
  );
}
