import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { BlogSchema } from "../blog-schema";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmdShiftU" });
  const post = await getTranslations({ locale, namespace: "blog.posts.cmdShiftU" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/blog/cmd-shift-u");
  const { title, description } = blogPostSeoCopy(locale, "cmdShiftU", t, post, siteMeta);
  return {
    title: { absolute: title },
    description,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-03-04T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function CmdShiftUPage() {
  const t = useTranslations("blog.posts.cmdShiftU");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema postKey="cmdShiftU" seoKey="cmdShiftU" path="/blog/cmd-shift-u" datePublished="2026-03-04T00:00:00Z" />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-03-04" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>

      <video
        src="/blog/cmd-shift-u.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p>
        {t.rich("p2", {
          link: (chunks) => (
            <Link href="/docs/notifications">{chunks}</Link>
          ),
        })}
      </p>
    </>
  );
}
