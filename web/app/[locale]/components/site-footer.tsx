import { getLocale, getTranslations } from "next-intl/server";
import { Link } from "../../../i18n/navigation";
import { fallbackContentLocales } from "../../../i18n/locale-availability";
import type { Locale } from "../../../i18n/routing";
import { LanguageSwitcher } from "./language-switcher";
import { ProUpgradeVisibility } from "./pro-upgrade-visibility";
import { ContentLocaleLink } from "./content-locale-link";

function isExternal(href: string) {
  return href.startsWith("http") || href.startsWith("mailto:");
}

type FooterLink = {
  label: string;
  href: string;
  proUpgrade?: boolean;
  unlocalized?: boolean;
  contentLocales?: readonly Locale[];
};

type FooterColumn = {
  heading: string;
  links: FooterLink[];
};

export async function SiteFooter() {
  const t = await getTranslations("footer");
  const locale = await getLocale();
  const year = new Date().getFullYear();

  const columns: FooterColumn[] = [
    {
      heading: t("product"),
      links: [
        {
          label: t("pricing"),
          href: "/pricing",
          proUpgrade: true,
          contentLocales: fallbackContentLocales,
        },
        { label: t("blog"), href: "/blog" },
        { label: t("community"), href: "/community" },
        { label: t("nightly"), href: "/nightly" },
        { label: t("assets"), href: "/assets" },
      ] satisfies FooterLink[],
    },
    {
      heading: t("resources"),
      links: [
        { label: t("docs"), href: "/docs/getting-started" },
        { label: t("guides"), href: "/guides" },
        { label: t("compare"), href: "/compare" },
        { label: t("changelog"), href: "/docs/changelog" },
      ] satisfies FooterLink[],
    },
    {
      heading: t("legal"),
      links: [
        { label: t("privacy"), href: "/privacy-policy" },
        { label: t("terms"), href: "/terms-of-service", unlocalized: true },
        { label: t("eula"), href: "/eula", unlocalized: true },
      ] satisfies FooterLink[],
    },
    {
      heading: t("social"),
      links: [
        { label: t("github"), href: "https://github.com/manaflow-ai/cmux" },
        { label: t("twitter"), href: "https://twitter.com/manaflowai" },
        { label: t("discord"), href: "https://discord.gg/xsgFEVrWCZ" },
        { label: t("contact"), href: "mailto:founders@manaflow.com" },
      ] satisfies FooterLink[],
    },
  ];

  return (
    <footer className="mt-16">
      <div className="max-w-2xl mx-auto px-6 py-12">
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-8">
          {columns.map((col) => (
            <div key={col.heading}>
              <h3 className="text-xs font-medium text-muted tracking-tight mb-3">
                {col.heading}
              </h3>
              <ul className="space-y-2">
                {col.links.map((link) => {
                  const item = (
                    <li key={link.href}>
                      {isExternal(link.href) || link.unlocalized ? (
                        <a
                          href={link.href}
                          target={isExternal(link.href) ? "_blank" : undefined}
                          rel={
                            isExternal(link.href)
                              ? "noopener noreferrer"
                              : undefined
                          }
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </a>
                      ) : link.contentLocales ? (
                        <ContentLocaleLink
                          href={link.href}
                          currentLocale={locale}
                          contentLocales={link.contentLocales}
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </ContentLocaleLink>
                      ) : (
                        <Link
                          href={link.href}
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </Link>
                      )}
                    </li>
                  );
                  return link.proUpgrade ? (
                    <ProUpgradeVisibility key={link.href}>
                      {item}
                    </ProUpgradeVisibility>
                  ) : (
                    item
                  );
                })}
              </ul>
            </div>
          ))}
        </div>
        <div className="flex items-center justify-between mt-10">
          <p className="text-xs text-muted">
            {t("copyright", { year })}
            <span aria-hidden className="mx-2">
              ·
            </span>
            <a
              href="https://github.com/manaflow-ai/cmux"
              target="_blank"
              rel="noopener noreferrer"
              className="hover:text-foreground transition-colors"
            >
              {t("openSource")}
            </a>
          </p>
          <LanguageSwitcher />
        </div>
      </div>
    </footer>
  );
}
