"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "../../../i18n/navigation";
import {
  navItemsForLocale,
  flatNavItems,
} from "./docs-nav-items";
import { ContentLocaleLink } from "./content-locale-link";
import { docsChannelUrl, docsNavPath } from "@/app/lib/docs-channel";
import { useDocsChannel } from "./docs-channel-context";

export function DocsPager() {
  const pathname = usePathname();
  const locale = useLocale();
  const channel = useDocsChannel();
  const t = useTranslations("docs.navItems");
  const flat = flatNavItems(navItemsForLocale(locale, channel));
  const releasePathname = docsNavPath(pathname, locale);
  const index = flat.findIndex((item) => item.href === releasePathname);
  const prev = index > 0 ? flat[index - 1] : null;
  const next = index < flat.length - 1 ? flat[index + 1] : null;

  if (!prev && !next) return null;

  return (
    <nav className="flex items-center justify-between mt-12 pt-6 border-t border-border text-[14px]">
      {prev ? (
        <ContentLocaleLink
          href={docsChannelUrl(channel, prev.href)}
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
          href={docsChannelUrl(channel, next.href)}
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
