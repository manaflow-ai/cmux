import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";
import { CodeBlock } from "../../components/code-block";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog.cmuxHistory" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    keywords: [
      "cmux",
      "history",
      "reopen closed terminal",
      "restore closed tab",
      "reopen terminal tab",
      "reopen closed workspace",
      "terminal history",
      "Cmd+Shift+T",
      "focus history",
      "Claude Code",
      "Codex",
      "OpenCode",
      "macOS",
      "AI coding agents",
    ],
    openGraph: {
      title: t("metaTitle"),
      description: t("metaDescription"),
      type: "article",
      publishedTime: "2026-06-02T00:00:00Z",
    },
    twitter: {
      card: "summary_large_image",
      title: t("metaTitle"),
      description: t("metaDescription"),
    },
    alternates: buildAlternates(locale, "/blog/cmux-history"),
  };
}

export default function CmuxHistoryBlogPage() {
  const t = useTranslations("blog.posts.cmuxHistory");
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
      <time dateTime="2026-06-02" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>

      <video
        src="/blog/cmux-history.mp4"
        width={1280}
        height={990}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <h2>{t("reopenTitle")}</h2>
      <p>
        {t.rich("reopenP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("agentTitle")}</h2>
      <p>
        {t.rich("agentP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock lang="bash">{`cmux hooks setup`}</CodeBlock>
      <p>
        {t.rich("agentP2", {
          link: (chunks) => <Link href="/blog/session-restore">{chunks}</Link>,
        })}
      </p>

      <h2>{t("focusTitle")}</h2>
      <p>
        {t.rich("focusP", {
          code: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("fullHistoryTitle")}</h2>
      <p>{t("fullHistoryP")}</p>

      <p className="mt-6">
        {t.rich("docsCta", {
          link: (chunks) => <Link href="/docs/keyboard-shortcuts">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
