"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "../../../i18n/navigation";
import {
  navItemsForLocale,
  flatNavItems,
} from "./docs-nav-items";
import { ContentLocaleLink } from "./content-locale-link";

export function DocsPager() {
  const pathname = usePathname();
  const locale = useLocale();
  const t = useTranslations("docs.navItems");
  const flat = flatNavItems(navItemsForLocale(locale));
  const index = flat.findIndex((item) => item.href === pathname);
  const prev = index > 0 ? flat[index - 1] : null;
  const next = index < flat.length - 1 ? flat[index + 1] : null;

  if (!prev && !next) return null;

  return (
    <nav className="flex items-center justify-between mt-12 pt-6 border-t border-border text-[14px]">
      {prev ? (
        <ContentLocaleLink
          href={prev.href}
          currentLocale={locale}
          contentLocales={prev.contentLocales}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          <span aria-hidden>&larr;</span>
          {t(prev.titleKey)}
        </ContentLocaleLink>
      ) : (
        <span />
      )}
      {next ? (
        <ContentLocaleLink
          href={next.href}
          currentLocale={locale}
          contentLocales={next.contentLocales}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          {t(next.titleKey)}
          <span aria-hidden>&rarr;</span>
        </ContentLocaleLink>
      ) : (
        <span />
      )}
    </nav>
  );
}
