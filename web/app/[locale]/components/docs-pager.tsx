"use client";

import { useTranslations } from "next-intl";
import { Link, usePathname } from "../../../i18n/navigation";
import { navItems } from "./docs-nav-items";

export function DocsPager() {
  const pathname = usePathname();
  const t = useTranslations("docs.navItems");
  const index = navItems.findIndex((item) => item.href === pathname);
  const prev = index > 0 ? navItems[index - 1] : null;
  const next = index < navItems.length - 1 ? navItems[index + 1] : null;

  if (!prev && !next) return null;

  return (
    <nav className="flex items-center justify-between mt-12 pt-6 border-t border-border text-[14px]">
      {prev ? (
        <Link
          href={prev.href}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          <span aria-hidden>&larr;</span>
          {t(prev.titleKey)}
        </Link>
      ) : (
        <span />
      )}
      {next ? (
        <Link
          href={next.href}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          {t(next.titleKey)}
          <span aria-hidden>&rarr;</span>
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
