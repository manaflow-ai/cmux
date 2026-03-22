import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.introducingCmux" });
  const url = locale === "en" ? "/blog/introducing-cmux" : `/${locale}/blog/introducing-cmux`;
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux", "terminal", "macOS", "Ghostty", "libghostty",
      "AI coding agents", "Claude Code", "vertical tabs", "split panes", "socket API",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-02-12T00:00:00Z",
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

export default function IntroducingCmuxPage() {
  const t = useTranslations("blog.posts.introducingCmux");
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
      <time dateTime="2026-02-12" className="text-sm text-muted">{t("date")}</time>

      <p className="mt-6">{t("p1")}</p>

      <h2>{t("whyTitle")}</h2>
      <p>{t("whyP")}</p>

      <h2>{t("featuresTitle")}</h2>
      <ul>
        <li><strong>{t("featureVerticalTabsLabel")}</strong>: {t("featureVerticalTabsDesc")}</li>
        <li><strong>{t("featureNotificationsLabel")}</strong>: {t("featureNotificationsDesc")}</li>
        <li><strong>{t("featureSplitPanesLabel")}</strong>: {t("featureSplitPanesDesc")}</li>
        <li><strong>{t("featureSocketApiLabel")}</strong>: {t("featureSocketApiDesc")}</li>
        <li><strong>{t("featureGpuLabel")}</strong>: {t("featureGpuDesc")}</li>
      </ul>

      <h2>{t("getStartedTitle")}</h2>
      <p>
        {t.rich("getStartedP", {
          link: (chunks) => <Link href="/docs/getting-started">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
