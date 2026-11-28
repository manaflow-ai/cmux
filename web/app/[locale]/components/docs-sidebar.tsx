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
      className={`mb-px block rounded-xl py-1.5 pl-4 pr-3 text-[14px] leading-5 transition-colors ${
        active
          ? "bg-foreground/[0.06] font-medium text-foreground dark:bg-foreground/[0.09]"
          : "text-foreground/70 hover:bg-foreground/[0.03] hover:text-foreground"
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
      <div className="pb-6">
        <DocsSearchTrigger onOpen={onOpenSearch} />
      </div>
      <nav data-pagefind-ignore="all">
        {navItems.map((entry) => {
          if (isSection(entry)) {
            return (
              <div key={entry.sectionKey} className="pt-8 first:pt-0">
                <div className="pb-2.5 pl-4 text-[12px] font-semibold leading-4 text-foreground">
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
