import { getTranslations } from "next-intl/server";
import { Link } from "../../../i18n/navigation";
import { LanguageSwitcher } from "./language-switcher";

function isExternal(href: string) {
  return href.startsWith("http") || href.startsWith("mailto:");
}

export async function SiteFooter() {
  const t = await getTranslations("footer");
  const year = new Date().getFullYear();

  const columns = [
    {
      heading: t("product"),
      links: [
        { label: t("blog"), href: "/blog" },
        { label: t("community"), href: "/community" },
        { label: t("nightly"), href: "/nightly" },
      ],
    },
    {
      heading: t("resources"),
      links: [
        { label: t("docs"), href: "/docs/getting-started" },
        { label: t("changelog"), href: "/docs/changelog" },
      ],
    },
    {
      heading: t("legal"),
      links: [
        { label: t("privacy"), href: "/privacy-policy" },
        { label: t("terms"), href: "/terms-of-service" },
        { label: t("eula"), href: "/eula" },
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
      <div className="max-w-2xl mx-auto flex flex-col gap-10 px-6 py-12">
        <div className="grid grid-cols-2 gap-x-8 gap-y-10 sm:grid-cols-4">
          {columns.map((col) => (
            <div key={col.heading} className="min-w-0">
              <h3 className="text-xs font-medium text-muted tracking-tight mb-3">
                {col.heading}
              </h3>
              <ul className="space-y-2">
                {col.links.map((link) => (
                  <li key={link.href}>
                    {isExternal(link.href) ? (
                      <a
                        href={link.href}
                        target="_blank"
                        rel="noopener noreferrer"
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
                ))}
              </ul>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap items-start justify-between gap-x-8 gap-y-3 sm:items-center">
          <p className="min-w-0 text-xs text-muted">
            {t("copyright", { year })}
          </p>
          <LanguageSwitcher />
        </div>
      </div>
    </footer>
  );
}
