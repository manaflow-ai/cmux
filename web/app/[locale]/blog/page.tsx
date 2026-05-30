import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../i18n/seo";
import { Link } from "../../../i18n/navigation";
import { blogPosts } from "../components/blog-posts";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/blog"),
  };
}

export default function BlogPage() {
  const t = useTranslations("blog");

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
