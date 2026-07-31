"use client";

import { UserButton } from "@stackframe/stack";
import { useTranslations } from "next-intl";
import { ThemeToggle } from "@/app/[locale]/theme";
import { Link, usePathname } from "@/i18n/navigation";

export function DashboardShell({ children }: { children: React.ReactNode }) {
  const t = useTranslations("dashboard.nav");
  const pathname = usePathname();
  const groups = [
    {
      label: t("cloudGroup"),
      items: [
        {
          href: "/home",
          label: t("cloudOverview"),
          active: pathname.startsWith("/home"),
          marker: "#",
        },
      ],
    },
    {
      label: t("vaultGroup"),
      items: [
        {
          href: "/dashboard/vault",
          label: t("vaultOverview"),
          active: pathname === "/dashboard/vault",
          marker: "#",
        },
        {
          href: "/dashboard/vault/sessions",
          label: t("vaultSessions"),
          active: pathname.startsWith("/dashboard/vault/sessions"),
          marker: "#",
        },
        {
          href: "/dashboard/vault/cli-auth",
          label: t("vaultCliSetup"),
          active: pathname.startsWith("/dashboard/vault/cli-auth"),
          marker: "#",
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
          marker: "#",
        },
      ],
    },
    {
      label: t("accountGroup"),
      items: [
        {
          href: "/dashboard/billing",
          label: t("billing"),
          active: pathname.startsWith("/dashboard/billing"),
          marker: "•",
        },
        {
          href: "/dashboard/testflight",
          label: t("testflight"),
          active: pathname.startsWith("/dashboard/testflight"),
          marker: "•",
        },
      ],
    },
  ];

  return (
    <div className="min-h-screen bg-background text-sm text-foreground md:h-screen md:overflow-hidden">
      <header className="sticky top-0 z-30 h-[52px] border-b border-border bg-background/95 backdrop-blur">
        <div className="flex h-full items-center justify-between px-3 md:px-4">
          <Link
            href="/dashboard"
            className="flex items-center gap-2 font-semibold tracking-tight focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground"
          >
            <span className="grid size-7 place-items-center rounded-lg bg-foreground font-mono text-xs text-background">cm</span>
            <span>{t("brand")}</span>
            <span className="rounded-md bg-code-bg px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-muted">{t("cloudBadge")}</span>
          </Link>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <UserButton />
          </div>
        </div>
      </header>
      <div className="grid min-h-[calc(100vh-52px)] grid-cols-1 md:h-[calc(100vh-52px)] md:grid-cols-[64px_244px_minmax(0,1fr)]">
        <aside className="hidden border-r border-border bg-code-bg/50 py-3 md:flex md:flex-col md:items-center md:gap-3">
          <Link href="/home" aria-label={t("cloudOverview")} className="grid size-10 place-items-center rounded-xl bg-foreground font-mono text-xs font-semibold text-background shadow-sm">
            C
          </Link>
          <Link href="/dashboard/vault" aria-label={t("vaultOverview")} className="grid size-10 place-items-center rounded-xl border border-border bg-background font-mono text-xs font-semibold text-muted transition-colors hover:text-foreground">
            V
          </Link>
          <Link href="/dashboard/subrouter" aria-label={t("subrouterOverview")} className="grid size-10 place-items-center rounded-xl border border-border bg-background font-mono text-[10px] font-semibold text-muted transition-colors hover:text-foreground">
            AI
          </Link>
        </aside>
        <aside className="border-b border-border bg-code-bg/25 px-3 py-3 md:overflow-y-auto md:border-b-0 md:border-r md:px-3 md:py-4">
          <div className="mb-4 hidden items-center justify-between px-2 md:flex">
            <div>
              <p className="text-[11px] font-semibold uppercase tracking-[0.16em] text-muted">{t("workspace")}</p>
              <p className="mt-1 font-semibold">{t("personalWorkspace")}</p>
            </div>
            <span aria-hidden="true" className="text-muted">⌄</span>
          </div>
          <nav aria-label={t("navigationLabel")} className="flex gap-4 overflow-x-auto md:flex-col md:gap-4">
            {groups.map((group) => (
              <div key={group.label} className="flex min-w-max gap-2 md:flex-col md:gap-1">
                <p className="px-2 text-[10px] font-semibold uppercase tracking-[0.14em] text-muted">{group.label}</p>
                <div className="flex gap-1 md:flex-col">
                  {group.items.map((item) => (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={`flex items-center gap-2 whitespace-nowrap rounded-md px-2 py-1.5 text-xs font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-foreground ${
                        item.active
                          ? "bg-foreground text-background"
                          : "text-muted hover:bg-code-bg hover:text-foreground"
                      }`}
                    >
                      <span aria-hidden="true" className="w-3 text-center font-mono text-[11px] opacity-65">{item.marker}</span>
                      {item.label}
                    </Link>
                  ))}
                </div>
              </div>
            ))}
          </nav>
        </aside>
        <main className="min-w-0 md:overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}
