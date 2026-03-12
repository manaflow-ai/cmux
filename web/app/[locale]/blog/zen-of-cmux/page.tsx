import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { Link } from "../../../../i18n/navigation";

export const metadata: Metadata = {
  title: "The Zen of cmux",
  description:
    "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
  keywords: [
    "cmux", "terminal", "macOS", "CLI", "composable",
    "developer tools", "AI coding agents", "workflow",
  ],
  openGraph: {
    title: "The Zen of cmux",
    description:
      "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
    type: "article",
    publishedTime: "2026-02-27T00:00:00Z",
    url: "https://cmux.dev/blog/zen-of-cmux",
  },
  twitter: {
    card: "summary",
    title: "The Zen of cmux",
    description:
      "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
  },
  alternates: { canonical: "https://cmux.dev/blog/zen-of-cmux" },
};

export default function ZenOfCmuxPage() {
  const t = useTranslations("blog.posts.zenOfCmux");
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
