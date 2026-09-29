"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "../../../i18n/navigation";
import {
  navItemsForLocale,
  isSection,
  type NavLink,
} from "./docs-nav-items";
import { DocsSearchTrigger } from "./docs-search-dialog";
import { ContentLocaleLink } from "./content-locale-link";
import { DocsVersionPicker } from "./docs-version-picker";
import { docsChannelUrl, type DocsChannel } from "@/app/lib/docs-channel";

function SidebarLink({
  item,
  locale,
  channel,
  pathname,
  onNavigate,
  t,
}: {
  item: NavLink;
  locale: string;
  channel: DocsChannel;
  pathname: string;
  onNavigate?: () => void;
  t: (key: string) => string;
}) {
  const active = docsChannelUrl("release", pathname) === item.href;
  return (
    <ContentLocaleLink
      href={docsChannelUrl(channel, item.href)}
      currentLocale={locale}
      contentLocales={item.contentLocales}
      onClick={onNavigate}
      aria-current={active ? "page" : undefined}
      className={`block rounded-xl px-3 py-1.5 text-[14px] leading-snug transition-colors ${
        active
          ? "bg-docs-primary/10 font-medium text-docs-primary"
          : "text-muted hover:bg-foreground/[0.04] hover:text-foreground"
      }`}
    >
      {t(item.titleKey)}
    </ContentLocaleLink>
  );
}

export function DocsSidebar({
  onNavigate,
  onOpenSearch,
  channel,
}: {
  onNavigate?: () => void;
  onOpenSearch: () => void;
  channel: "release" | "nightly";
}) {
  const pathname = usePathname();
  const locale = useLocale();
  const t = useTranslations("docs.navItems");
  const navItems = navItemsForLocale(locale, channel);
  const releaseLabel = useTranslations("docs.api")("release");
  const nightlyLabel = useTranslations("footer")("nightly");

  return (
    <>
      <div className="pb-5">
        <DocsSearchTrigger onOpen={onOpenSearch} />
      </div>
      <nav className="space-y-0.5" data-pagefind-ignore="all">
        {navItems.map((entry) => {
          if (isSection(entry)) {
            return (
              <div key={entry.sectionKey} className="pt-6 pb-1 first:pt-0">
                <div className="px-3 pb-2 text-[13px] font-semibold text-foreground">
                  {t(entry.sectionKey)}
                </div>
                {entry.children.map((child) => (
                  <SidebarLink
                    key={child.href}
                    item={child}
                    locale={locale}
                    channel={channel}
                    pathname={pathname}
                    onNavigate={onNavigate}
                    t={t}
                  />
                ))}
              </div>
            );
          }
          return (
            <SidebarLink
              key={entry.href}
              item={entry}
              locale={locale}
              channel={channel}
              pathname={pathname}
              onNavigate={onNavigate}
              t={t}
            />
          );
        })}
      </nav>
      <DocsVersionPicker
        channel={channel}
        releaseLabel={releaseLabel}
        nightlyLabel={nightlyLabel}
      />
    </>
  );
}
