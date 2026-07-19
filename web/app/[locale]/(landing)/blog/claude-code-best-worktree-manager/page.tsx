import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { blogPostSeoCopy } from "@/i18n/audited-seo";
import { Link } from "@/i18n/navigation";
import { BlogSchema } from "../blog-schema";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({
    locale,
    namespace: "blog.claudeCodeBestWorktreeManager",
  });
  const post = await getTranslations({
    locale,
    namespace: "blog.posts.claudeCodeBestWorktreeManager",
  });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const rawKeywords = t.raw("metaKeywords");
  const keywords = Array.isArray(rawKeywords)
    ? rawKeywords.filter((keyword): keyword is string => typeof keyword === "string")
    : [];
  const alternates = buildAlternates(locale, "/blog/claude-code-best-worktree-manager");
  const { title, description } = blogPostSeoCopy(
    locale,
    "claudeCodeBestWorktreeManager",
    t,
    post,
    siteMeta,
  );
  return {
    title: { absolute: title },
    description,
    keywords,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
      publishedTime: "2026-07-03T00:00:00Z",
    },
    twitter: twitterSummary(locale, title, description),
    alternates,
  };
}

export default function ClaudeCodeBestWorktreeManagerPage() {
  const t = useTranslations("blog.posts.claudeCodeBestWorktreeManager");
  const tc = useTranslations("common");

  return (
    <>
      <BlogSchema
        postKey="claudeCodeBestWorktreeManager"
        seoKey="claudeCodeBestWorktreeManager"
        path="/blog/claude-code-best-worktree-manager"
        datePublished="2026-07-03T00:00:00Z"
      />
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; {tc("backToBlog")}
        </Link>
      </div>

      <h1>{t("title")}</h1>
      <time dateTime="2026-07-03" className="text-sm text-muted">
        {t("date")}
      </time>

      <p className="mt-6">{t("p1")}</p>
      <p>
        {t.rich("p2", {
          zen: (chunks) => <Link href="/blog/zen-of-cmux">{chunks}</Link>,
        })}
      </p>

      <h2>{t("superRepoTitle")}</h2>
      <p>{t("superRepoP1")}</p>
      <p>{t("superRepoP2")}</p>

      <h2>{t("agentTitle")}</h2>
      <p>{t("agentP1")}</p>
      <p>{t("agentP2")}</p>

      <h2>{t("limitsTitle")}</h2>
      <p>{t("limitsP1")}</p>
      <p>{t("limitsP2")}</p>

      <h2>{t("cmuxTitle")}</h2>
      <p>
        {t.rich("cmuxP1", {
          customCommands: (chunks) => (
            <Link href="/docs/custom-commands#new-workspace-button">
              {chunks}
            </Link>
          ),
          api: (chunks) => <Link href="/docs/api">{chunks}</Link>,
          skills: (chunks) => <Link href="/docs/skills">{chunks}</Link>,
        })}
      </p>
      <p>
        {t.rich("cmuxP2", {
          home: (chunks) => <Link href="/blog/cmux-home">{chunks}</Link>,
        })}
      </p>
    </>
  );
}
