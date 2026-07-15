"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname } from "../../../i18n/navigation";
import { navItemsForLocale, isSection, type NavLink } from "./docs-nav-items";
import { DocsSearch } from "./docs-search";
import { DocsVersionPicker } from "./docs-version-picker";
import { DocsLink } from "./docs-link";

function SidebarLink({
  item,
  pathname,
  onNavigate,
  indent,
  t,
}: {
  item: NavLink;
  pathname: string;
  onNavigate?: () => void;
  indent?: boolean;
  t: (key: string) => string;
}) {
  const active = pathname === item.href;
  return (
    <DocsLink
      href={item.href}
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
    </DocsLink>
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
  const navItems = navItemsForLocale(locale);
  const releaseLabel = useTranslations("docs.api")("release");
  const nightlyLabel = useTranslations("footer")("nightly");

  return (
    <>
      <DocsVersionPicker
        channel={channel}
        releaseLabel={releaseLabel}
        nightlyLabel={nightlyLabel}
      />
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
              pathname={pathname}
              onNavigate={onNavigate}
              t={t}
            />
          );
        })}
      </nav>
    </>
  );
}
