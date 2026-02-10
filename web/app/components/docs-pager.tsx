"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navItems } from "./docs-nav-items";

export function DocsPager() {
  const pathname = usePathname();
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
          {prev.title}
        </Link>
      ) : (
        <span />
      )}
      {next ? (
        <Link
          href={next.href}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          {next.title}
          <span aria-hidden>&rarr;</span>
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
