import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { Link } from "../../../../i18n/navigation";

export const metadata: Metadata = {
  title: "Introducing cmux",
  description:
    "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
  keywords: [
    "cmux", "terminal", "macOS", "Ghostty", "libghostty",
    "AI coding agents", "Claude Code", "vertical tabs", "split panes", "socket API",
  ],
  openGraph: {
    title: "Introducing cmux",
    description:
      "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
    type: "article",
    publishedTime: "2026-02-12T00:00:00Z",
    url: "https://cmux.dev/blog/introducing-cmux",
  },
  twitter: {
    card: "summary",
    title: "Introducing cmux",
    description:
      "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
  },
  alternates: { canonical: "https://cmux.dev/blog/introducing-cmux" },
};

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
        <li><strong>Vertical tabs</strong>: {t("featureVerticalTabs").split(": ")[1] || t("featureVerticalTabs")}</li>
        <li><strong>Notification rings</strong>: {t("featureNotifications").split(": ")[1] || t("featureNotifications")}</li>
        <li><strong>Split panes</strong>: {t("featureSplitPanes").split(": ")[1] || t("featureSplitPanes")}</li>
        <li><strong>Socket API</strong>: {t("featureSocketApi").split(": ")[1] || t("featureSocketApi")}</li>
        <li><strong>GPU-accelerated</strong>: {t("featureGpu").split(": ")[1] || t("featureGpu")}</li>
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
