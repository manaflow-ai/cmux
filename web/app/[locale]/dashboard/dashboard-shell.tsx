"use client";

import { UserButton } from "@stackframe/stack";
import { useTranslations } from "next-intl";
import { Link, usePathname } from "@/i18n/navigation";

export function DashboardShell({ children }: { children: React.ReactNode }) {
  const t = useTranslations("vault.nav");
  const pathname = usePathname();
  const items = [
    { href: "/dashboard/vault", label: t("overview"), active: pathname === "/dashboard/vault" },
    {
      href: "/dashboard/vault/sessions",
      label: t("sessions"),
      active: pathname.startsWith("/dashboard/vault/sessions"),
    },
    {
      href: "/dashboard/vault/cli-auth",
      label: t("cliSetup"),
      active: pathname.startsWith("/dashboard/vault/cli-auth"),
    },
  ];

  return (
    <div className="min-h-screen bg-background text-sm text-foreground">
      <header className="sticky top-0 z-30 border-b border-border bg-background">
        <div className="flex h-11 items-center justify-between px-3">
          <Link
            href="/dashboard/vault"
            className="font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {t("brand")}
          </Link>
          <UserButton />
        </div>
      </header>
      <div className="grid min-h-[calc(100vh-2.75rem)] grid-cols-1 md:grid-cols-[220px_minmax(0,1fr)]">
        <aside className="border-b border-border px-3 py-3 md:border-b-0 md:border-r">
          <nav className="flex gap-2 overflow-x-auto md:flex-col">
            {items.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`whitespace-nowrap border border-border px-3 py-1.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                  item.active
                    ? "bg-foreground text-background"
                    : "bg-background text-foreground hover:bg-foreground hover:text-background"
                }`}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </aside>
        <main className="min-w-0">{children}</main>
      </div>
    </div>
  );
}
