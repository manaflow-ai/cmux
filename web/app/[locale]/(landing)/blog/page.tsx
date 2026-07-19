import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogIndexSeoCopy } from "@/i18n/audited-seo";
import { Link } from "@/i18n/navigation";
import { blogPostsForLocale } from "@/app/[locale]/components/blog-posts";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/blog");
  const { title, description } = blogIndexSeoCopy(locale, t, siteMeta);
  return {
    title: { absolute: title },
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default function BlogPage() {
  const t = useTranslations("blog");
  const locale = useLocale();
  const blogPosts = blogPostsForLocale(locale);

  return (
    <>
      <h1>{t("title")}</h1>
      <div className="space-y-4 mt-6">
        {blogPosts.map((post) => (
          <article key={post.slug}>
            <Link
              href={`/blog/${post.slug}`}
              className="block group"
            >
              <h2 className="text-lg font-medium group-hover:underline">
                {t(`posts.${post.key}.title`)}
              </h2>
              <time className="text-sm text-muted">
                {t(`posts.${post.key}.date`)}
              </time>
              <p className="mt-1 text-muted">
                {t(`posts.${post.key}.summary`)}
              </p>
            </Link>
          </article>
        ))}
      </div>
    </>
  );
}
