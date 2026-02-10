"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navItems } from "./docs-nav-items";

export function DocsSidebar({ onNavigate }: { onNavigate?: () => void }) {
  const pathname = usePathname();

  return (
    <nav className="space-y-0.5">
      {navItems.map((item) => {
        const active = pathname === item.href;
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            className={`block px-3 py-1.5 text-[14px] rounded-md transition-colors ${
              active
                ? "text-foreground font-medium bg-code-bg"
                : "text-muted hover:text-foreground"
            }`}
          >
            {item.title}
          </Link>
        );
      })}
    </nav>
  );
}
