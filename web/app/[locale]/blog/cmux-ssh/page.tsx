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

      <p className="mt-6">{t("intro")}</p>

      <h2>{t("problemTitle")}</h2>
      <p>{t("problemP1")}</p>
      <p>{t("problemP2")}</p>

      <h2>{t("howTitle")}</h2>
      <p>{t("howP1")}</p>

      <pre className="bg-zinc-900 text-zinc-100 rounded-lg p-4 my-4 overflow-x-auto text-sm">
        <code>cmux ssh user@devbox</code>
      </pre>

      <p>{t("howP2")}</p>
      <p>{t("howP3")}</p>

      <h2>{t("browserTitle")}</h2>
      <p>{t("browserP1")}</p>
      <p>{t("browserP2")}</p>

      <h2>{t("notificationsTitle")}</h2>
      <p>{t("notificationsP1")}</p>
      <p>{t("notificationsP2")}</p>

      <h2>{t("agentsTitle")}</h2>
      <p>{t("agentsP1")}</p>

      <pre className="bg-zinc-900 text-zinc-100 rounded-lg p-4 my-4 overflow-x-auto text-sm">
        <code>{t("agentsCode")}</code>
      </pre>

      <p>{t("agentsP2")}</p>

      <h2>{t("architectureTitle")}</h2>
      <p>{t("architectureP1")}</p>
      <p>{t("architectureP2")}</p>
      <p>{t("architectureP3")}</p>

      <h2>{t("detailsTitle")}</h2>
      <p>{t("detailsP1")}</p>
      <p>{t("detailsP2")}</p>
      <p>{t("detailsP3")}</p>

      <p className="mt-6">
        {t.rich("cta", {
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
