import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxHome" });
  const post = await getTranslations({ locale, namespace: "blog.posts.cmuxHome" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/blog/cmux-home");
  const { title, description } = blogPostSeoCopy(locale, "cmuxHome", t, post, siteMeta);
  return {
    title: { absolute: title },
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-06-23T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmuxHomeBlogPage() {
  const t = useTranslations("blog.posts.cmuxHome");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="cmuxHome" seoKey="cmuxHome" path="/blog/cmux-home" datePublished="2026-06-23T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-06-23" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">
        {t.rich("p1", {
          link: (chunks) => <Link href="/blog/zen-of-cmux">{chunks}</Link>,
        })}
      </p>
      <p>{t("p2")}</p>
      <p>{t("p3")}</p>
      <p>{t("p4")}</p>
      <p>
        {t.rich("p5", {
          link: (chunks) => (
            <a href="https://github.com/manaflow-ai/cmux-home">{chunks}</a>
          ),
        })}
      </p>
    </>
  );
}
