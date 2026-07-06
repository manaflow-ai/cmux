"use client";

import { Suspense } from "react";
import { UserButton } from "@stackframe/stack";
import { useTranslations } from "next-intl";
import { ThemeToggle } from "@/app/[locale]/theme";
import { Link, usePathname } from "@/i18n/navigation";

export function DashboardShell({ children }: { children: React.ReactNode }) {
  const t = useTranslations("dashboard.nav");
  const pathname = usePathname();
  const groups = [
    {
      label: t("vaultGroup"),
      items: [
        {
          href: "/dashboard/vault",
          label: t("vaultOverview"),
          active: pathname === "/dashboard/vault",
        },
        {
          href: "/dashboard/vault/sessions",
          label: t("vaultSessions"),
          active: pathname.startsWith("/dashboard/vault/sessions"),
        },
        {
          href: "/dashboard/vault/cli-auth",
          label: t("vaultCliSetup"),
          active: pathname.startsWith("/dashboard/vault/cli-auth"),
        },
      ],
    },
    {
      label: t("subrouterGroup"),
      items: [
        {
          href: "/dashboard/subrouter",
          label: t("subrouterOverview"),
          active: pathname.startsWith("/dashboard/subrouter"),
        },
      ],
    },
  ];

  return (
    <div className="min-h-screen bg-background text-sm text-foreground">
      <header className="sticky top-0 z-30 h-11 border-b border-border bg-background">
        <div className="flex h-full items-center justify-between px-3">
          <Link
            href="/dashboard"
            className="font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {t("brand")}
          </Link>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <Suspense fallback={null}>
              <UserButton />
            </Suspense>
          </div>
        </div>
      </header>
      <div className="grid min-h-[calc(100vh-2.75rem)] grid-cols-1 md:grid-cols-[220px_minmax(0,1fr)]">
        <aside className="border-b border-border px-3 py-3 md:border-b-0 md:border-r">
          <nav className="flex gap-4 overflow-x-auto md:flex-col">
            {groups.map((group) => (
              <div key={group.label} className="flex min-w-max gap-2 md:flex-col">
                <p className="text-[11px] font-semibold text-foreground">{group.label}</p>
                <div className="flex gap-3 md:flex-col md:gap-1">
                  {group.items.map((item) => (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={`whitespace-nowrap py-0.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                        item.active
                          ? "text-foreground"
                          : "text-muted hover:text-foreground"
                      }`}
                    >
                      {item.label}
                    </Link>
                  ))}
                </div>
              </div>
            ))}
          </nav>
        </aside>
        <main className="min-w-0">{children}</main>
      </div>
    </div>
  );
}
