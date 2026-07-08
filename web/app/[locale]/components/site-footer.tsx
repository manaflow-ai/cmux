import { getTranslations } from "next-intl/server";
import { Link } from "../../../i18n/navigation";
import { LanguageSwitcher } from "./language-switcher";
import { ProUpgradeVisibility } from "./pro-upgrade-visibility";

function isExternal(href: string) {
  return href.startsWith("http") || href.startsWith("mailto:");
}

type FooterLink = {
  label: string;
  href: string;
  proUpgrade?: boolean;
  defaultLocale?: boolean;
};

type FooterColumn = {
  heading: string;
  links: FooterLink[];
};

export async function SiteFooter() {
  const t = await getTranslations("footer");
  const year = new Date().getFullYear();

  const columns: FooterColumn[] = [
    {
      heading: t("product"),
      links: [
        { label: t("pricing"), href: "/pricing", proUpgrade: true },
        { label: t("blog"), href: "/blog" },
        { label: t("community"), href: "/community" },
        { label: t("nightly"), href: "/nightly" },
        { label: t("assets"), href: "/assets" },
      ],
    },
    {
      heading: t("resources"),
      links: [
        { label: t("docs"), href: "/docs/getting-started" },
        { label: t("guides"), href: "/guides" },
        { label: t("compare"), href: "/compare" },
        { label: t("changelog"), href: "/docs/changelog" },
      ],
    },
    {
      heading: t("legal"),
      links: [
        { label: t("privacy"), href: "/privacy-policy", defaultLocale: true },
        { label: t("terms"), href: "/terms-of-service", defaultLocale: true },
        { label: t("eula"), href: "/eula", defaultLocale: true },
      ],
    },
    {
      heading: t("social"),
      links: [
        { label: t("github"), href: "https://github.com/manaflow-ai/cmux" },
        { label: t("twitter"), href: "https://twitter.com/manaflowai" },
        { label: t("discord"), href: "https://discord.gg/xsgFEVrWCZ" },
        { label: t("contact"), href: "mailto:founders@manaflow.com" },
      ],
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
                      {isExternal(link.href) || link.defaultLocale ? (
                        <a
                          href={link.href}
                          {...(isExternal(link.href)
                            ? { target: "_blank", rel: "noopener noreferrer" }
                            : {})}
                          className="text-sm text-muted hover:text-foreground transition-colors"
                        >
                          {link.label}
                        </a>
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
