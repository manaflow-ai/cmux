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
  const t = await getTranslations({ locale, namespace: "blog.unreadShortcuts" });
  const post = await getTranslations({ locale, namespace: "blog.posts.unreadShortcuts" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  const alternates = buildAlternates(locale, "/blog/unread-shortcuts");
  const { title, description } = blogPostSeoCopy(locale, "unreadShortcuts", t, post, siteMeta);
  return {
    title: { absolute: title },
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

export default function UnreadShortcutsPage() {
  const t = useTranslations("blog.posts.unreadShortcuts");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="unreadShortcuts" seoKey="unreadShortcuts" path="/blog/unread-shortcuts" datePublished="2026-05-22T00:00:00Z" />
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
        src="/blog/cmd-ctrl-u-cmd-option-u.mp4"
        width={1280}
        height={866}
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
