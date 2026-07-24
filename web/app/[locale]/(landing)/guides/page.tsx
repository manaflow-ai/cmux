import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { landingPageSeoCopy } from "@/i18n/audited-seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { comparePages, comparePath } from "../../../lib/compare-pages";
import { TrackedLink } from "../tracked-link";
import { remoteTmuxDocsLocales } from "@/i18n/locale-availability";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.guides" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/guides");
  const { title, description } = landingPageSeoCopy(
    locale,
    t,
    siteMeta,
    {
      complete: ["intro"],
      context: ["title"],
    },
  );
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

type Article = {
  href: string;
  titleKey: string;
  descKey: string;
  locales?: readonly string[];
};

const ARTICLES: readonly Article[] = [
  { href: "/best-terminal-for-mac", titleKey: "bestTerminal.title", descKey: "bestTerminal.metaDescription" },
  { href: "/built-on-ghostty", titleKey: "ghostty.title", descKey: "ghostty.metaDescription" },
  { href: "/docs/remote-tmux", titleKey: "remoteTmux.title", descKey: "remoteTmux.metaDescription", locales: remoteTmuxDocsLocales },
  { href: "/agents", titleKey: "agents.title", descKey: "agents.metaDescription" },
  { href: "/agents/claude-code", titleKey: "claude.title", descKey: "claude.metaDescription" },
  { href: "/agents/codex", titleKey: "codex.title", descKey: "codex.metaDescription" },
  { href: "/agents/opencode", titleKey: "opencode.title", descKey: "opencode.metaDescription" },
  { href: "/agents/gemini-cli", titleKey: "geminiCli.title", descKey: "geminiCli.metaDescription" },
  { href: "/agents/aider", titleKey: "aider.title", descKey: "aider.metaDescription" },
  { href: "/agents/amp", titleKey: "amp.title", descKey: "amp.metaDescription" },
  { href: "/agents/cursor-cli", titleKey: "cursorCli.title", descKey: "cursorCli.metaDescription" },
  ...comparePages.map((page) => ({
    href: comparePath(page.slug),
    titleKey: `compare.pages.${page.key}.title`,
    descKey: `compare.pages.${page.key}.metaDescription`,
  })),
] as const;

export default function GuidesPage() {
  const t = useTranslations("landing");
  const locale = useLocale();
  const articles = ARTICLES.filter((article) => {
    return !article.locales || article.locales.includes(locale);
  });
  return (
    <>
      <SiteHeader section={t("guides.title")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <h1>{t("guides.title")}</h1>
          <p>{t("guides.intro")}</p>
          <ul className="not-prose mt-6 flex flex-col gap-5">
            {articles.map((a) => (
              <li key={a.href}>
                <TrackedLink
                  href={a.href}
                  event="guide_link_clicked"
                  className="text-base font-medium underline underline-offset-2"
                >
                  {t(a.titleKey)}
                </TrackedLink>
                <p className="text-muted text-sm mt-1">{t(a.descKey)}</p>
              </li>
            ))}
          </ul>
        </div>
      </main>
    </>
  );
}
