import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxSsh" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux", "SSH", "remote development", "terminal", "macOS",
      "port forwarding", "notifications", "AI coding agents",
      "Claude Code", "remote workspace", "developer tools",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-03-30T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-ssh"),
  };
}

export default function CmuxSshPage() {
  const t = useTranslations("blog.posts.cmuxSsh");
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
      <time dateTime="2026-03-30" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>

      <pre className="bg-zinc-900 text-zinc-100 rounded-lg p-4 my-4 overflow-x-auto text-sm">
        <code>cmux ssh user@devbox</code>
      </pre>

      <p>{t("p2")}</p>
      <p>{t("p3")}</p>
      <p>{t("p4")}</p>
      <p>{t("p5")}</p>

      <p>
        {t.rich("p6", {
          link: (chunks) => (
            <Link href="/docs/getting-started">{chunks}</Link>
          ),
          github: (chunks) => (
            <a href="https://github.com/manaflow-ai/cmux">{chunks}</a>
          ),
        })}
      </p>
    </>
  );
}
