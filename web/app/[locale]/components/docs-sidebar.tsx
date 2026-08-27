"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "../../../i18n/navigation";
import {
  navItemsForLocale,
  isSection,
  type NavLink,
} from "./docs-nav-items";
import { DocsSearch } from "./docs-search";
import { ContentLocaleLink } from "./content-locale-link";
import { DocsVersionPicker } from "./docs-version-picker";
import { docsChannelUrl, type DocsChannel } from "@/app/lib/docs-channel";

function SidebarLink({
  item,
  locale,
  channel,
  pathname,
  onNavigate,
  indent,
  t,
}: {
  item: NavLink;
  locale: string;
  channel: DocsChannel;
  pathname: string;
  onNavigate?: () => void;
  indent?: boolean;
  t: (key: string) => string;
}) {
  const active = docsChannelUrl("release", pathname) === item.href;
  return (
    <ContentLocaleLink
      href={docsChannelUrl(channel, item.href)}
      currentLocale={locale}
      contentLocales={item.contentLocales}
      onClick={onNavigate}
      className={`block py-1.5 text-[14px] rounded-md transition-colors ${
        indent ? "px-5" : "px-3"
      } ${
        active
          ? "text-foreground font-medium bg-code-bg"
          : "text-muted hover:text-foreground"
      }`}
    >
      {t(item.titleKey)}
    </ContentLocaleLink>
  );
}

export function DocsSidebar({
  onNavigate,
  channel,
}: {
  onNavigate?: () => void;
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
      <DocsSearch onNavigate={onNavigate} />
      <nav className="space-y-0.5" data-pagefind-ignore="all">
        {navItems.map((entry) => {
          if (isSection(entry)) {
            return (
              <div key={entry.sectionKey} className="pt-5 pb-2 first:pt-0">
                <div className="px-3 pb-1 text-[12px] font-medium text-muted tracking-wider">
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
                    indent
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
