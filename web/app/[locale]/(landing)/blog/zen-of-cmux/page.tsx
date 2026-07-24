import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.zenOfCmux" });
  const post = await getTranslations({ locale, namespace: "blog.posts.zenOfCmux" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/blog/zen-of-cmux");
  const { title, description } = blogPostSeoCopy(locale, "zenOfCmux", t, post, siteMeta);
  return {
    title: { absolute: title },
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-02-27T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function ZenOfCmuxPage() {
  const t = useTranslations("blog.posts.zenOfCmux");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="zenOfCmux" seoKey="zenOfCmux" path="/blog/zen-of-cmux" datePublished="2026-02-27T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-02-27" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>
      <p>{t("p2")}</p>
      <p>{t("p3")}</p>
      <p>{t("p4")}</p>
    </>
  );
}
