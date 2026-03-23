import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmdShiftU" });
  const url = locale === "en" ? "/blog/cmd-shift-u" : `/${locale}/blog/cmd-shift-u`;
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux", "terminal", "macOS", "notifications", "AI coding agents",
      "keyboard shortcuts", "developer tools", "workflow",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-03-04T00:00:00Z",
      url,
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: { canonical: url },
  };
}

export default function CmdShiftUPage() {
  const t = useTranslations("blog.posts.cmdShiftU");
  const tc = useTranslations("common");

  return (
    <>
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
