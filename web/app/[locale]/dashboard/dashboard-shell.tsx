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
    <div className="min-h-screen bg-background text-foreground">
      <header className="sticky top-0 z-30 border-b border-border bg-background">
        <div className="flex h-14 items-center justify-between px-4 sm:px-6">
          <Link href="/dashboard/vault" className="text-sm font-semibold tracking-tight">
            {t("brand")}
          </Link>
          <UserButton />
        </div>
      </header>
      <div className="grid min-h-[calc(100vh-3.5rem)] grid-cols-1 md:grid-cols-[220px_minmax(0,1fr)]">
        <aside className="border-b border-border px-4 py-3 md:border-b-0 md:border-r md:px-3 md:py-5">
          <nav className="flex gap-2 overflow-x-auto md:flex-col">
            {items.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`whitespace-nowrap rounded-md px-3 py-2 text-sm transition-colors ${
                  item.active
                    ? "bg-foreground text-background"
                    : "text-muted hover:bg-muted/10 hover:text-foreground"
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
