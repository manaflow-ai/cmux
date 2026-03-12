import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";

export const metadata: Metadata = {
  title: "Blog",
  description: "News and updates from the cmux team",
};

const blogSlugs = [
  "cmdShiftU",
  "zenOfCmux",
  "showHnLaunch",
  "introducingCmux",
] as const;

const slugToPath: Record<string, string> = {
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
