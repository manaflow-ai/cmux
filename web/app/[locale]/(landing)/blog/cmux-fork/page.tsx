import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxFork" });
  const alternates = buildAlternates(locale, "/blog/cmux-fork");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));

  return {
    title,
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-07-14T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmuxForkPage() {
  const t = useTranslations("blog.posts.cmuxFork");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema
        postKey="cmuxFork"
        path="/blog/cmux-fork"
        datePublished="2026-07-14T00:00:00Z"
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
      <time dateTime="2026-07-14" className="text-sm text-muted">
        {t("date")}
      </time>

      <video
        src="/blog/cmux-fork.mp4"
        width={1680}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p>{t("p1")}</p>
      <p>{t("p2")}</p>

      <h2>{t("destinationsTitle")}</h2>
      <p>
        {t.rich("destinationsP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("parallelTitle")}</h2>
      <p>{t("parallelP1")}</p>
      <p>{t("parallelP2")}</p>

      <p>{t("release")}</p>
    </>
  );
}
