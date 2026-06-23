import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxHome" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux",
      "cmux home",
      "git worktrees",
      "terminal",
      "macOS",
      "CLI",
      "composable",
      "customizable",
      "developer tools",
      "AI coding agents",
      "Claude Code",
      "Codex",
      "workflow",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-06-23T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-home"),
  };
}

export default function CmuxHomeBlogPage() {
  const t = useTranslations("blog.posts.cmuxHome");
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
