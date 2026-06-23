import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { TrackedLink } from "../tracked-link";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.guides" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/guides"),
  };
}

const ARTICLES = [
  { href: "/best-terminal-for-mac", titleKey: "bestTerminal.title", descKey: "bestTerminal.metaDescription" },
  { href: "/built-on-ghostty", titleKey: "ghostty.title", descKey: "ghostty.metaDescription" },
  { href: "/claude-code-terminal", titleKey: "claude.title", descKey: "claude.metaDescription" },
  { href: "/codex-cli", titleKey: "codex.title", descKey: "codex.metaDescription" },
  { href: "/opencode", titleKey: "opencode.title", descKey: "opencode.metaDescription" },
] as const;

export default function GuidesPage() {
  const t = useTranslations("landing");
  return (
    <>
      <h1>{t("guides.title")}</h1>
      <p>{t("guides.intro")}</p>
      <ul className="not-prose mt-6 flex flex-col gap-5">
        {ARTICLES.map((a) => (
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
    </>
  );
}
