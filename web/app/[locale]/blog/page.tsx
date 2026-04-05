import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../i18n/seo";
import { Link } from "../../../i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blog" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/blog"),
  };
}

const blogSlugs = [
  "cmuxSsh",
  "cmuxClaudeTeams",
  "cmuxOmo",
  "gpl",
  "cmdShiftU",
  "zenOfCmux",
  "showHnLaunch",
  "introducingCmux",
] as const;

const slugToPath: Record<string, string> = {
  cmuxOmo: "cmux-omo",
  cmuxClaudeTeams: "cmux-claude-teams",
  cmuxSsh: "cmux-ssh",
  gpl: "gpl",
  cmdShiftU: "cmd-shift-u",
  zenOfCmux: "zen-of-cmux",
  showHnLaunch: "show-hn-launch",
  introducingCmux: "introducing-cmux",
};

export default function BlogPage() {
  const t = useTranslations("blog");

  return (
    <>
      <h1>{t("title")}</h1>
      <div className="space-y-4 mt-6">
        {blogSlugs.map((slug) => (
          <article key={slug}>
            <Link
              href={`/blog/${slugToPath[slug]}`}
              className="block group"
            >
              <h2 className="text-lg font-medium group-hover:underline">
                {t(`posts.${slug}.title`)}
              </h2>
              <time className="text-sm text-muted">
                {t(`posts.${slug}.date`)}
              </time>
              <p className="mt-1 text-muted">
                {t(`posts.${slug}.summary`)}
              </p>
            </Link>
          </article>
        ))}
      </div>
    </>
  );
}
