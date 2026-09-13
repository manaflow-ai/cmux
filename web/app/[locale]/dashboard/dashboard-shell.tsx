"use client";

import { useTranslations } from "next-intl";
import { useState } from "react";
import { Link, usePathname } from "@/i18n/navigation";
import { Link as TanStackLink } from "@tanstack/react-router";

type DashboardNavGroup = {
  label: string;
  items: Array<{
    href: string;
    label: string;
    active: boolean;
  }>;
};

export function DashboardShell({
  children,
  vaultEnabled,
  account,
  routerEnabled = false,
  currentPathname,
}: {
  children: React.ReactNode;
  vaultEnabled: boolean;
  /** The identity row, streamed by the layout once the session resolves. */
  account?: React.ReactNode;
  /** Enables the mounted TanStack Router navigation layer. */
  routerEnabled?: boolean;
  /** The pathname reported by TanStack Router when the layer is mounted. */
  currentPathname?: string;
}) {
  const t = useTranslations("dashboard.nav");
  const common = useTranslations("common");
  const nextPathname = usePathname();
  const pathname = normalizeDashboardPath(currentPathname ?? nextPathname);
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const groups: DashboardNavGroup[] = [];
  if (vaultEnabled) {
    groups.push({
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
      ],
    });
  }
  groups.push(
    {
      label: t("cloudGroup"),
      items: [
        {
          href: "/dashboard/cloud",
          label: t("cloudDevices"),
          active: pathname.startsWith("/dashboard/cloud"),
        },
      ],
    },
    {
      label: t("coderouterGroup"),
      items: [
        {
          href: "/dashboard/coderouter",
          label: t("coderouterOverview"),
          active: pathname.startsWith("/dashboard/coderouter"),
        },
      ],
    },
    {
      label: t("iosGroup"),
      items: [
        {
          href: "/dashboard/testflight",
          label: t("testflight"),
          active: pathname.startsWith("/dashboard/testflight"),
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
        },
        {
          href: "/dashboard/team",
          label: t("team"),
          active: pathname.startsWith("/dashboard/team"),
        },
      ],
    },
  );

  return (
    <div
      data-testid="dashboard-shell"
      data-dashboard-router={routerEnabled ? "tanstack" : undefined}
      className="min-h-screen bg-background text-sm text-foreground sm:grid sm:grid-cols-[13rem_minmax(0,1fr)]"
    >
      <aside className="sticky top-0 hidden h-screen flex-col border-r border-border bg-background sm:flex">
        <div className="flex h-11 shrink-0 items-center border-b border-border px-3">
          <DashboardBrandLink
            routerEnabled={routerEnabled}
            className="font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {t("brand")}
          </DashboardBrandLink>
        </div>
        <DashboardNav
          groups={groups}
          routerEnabled={routerEnabled}
          className="flex-1 overflow-y-auto px-2 py-3 pb-28"
        />
      </aside>

      <div className="min-w-0">
        <header className="sticky top-0 z-30 border-b border-border bg-background sm:fixed sm:inset-x-auto sm:bottom-0 sm:left-0 sm:top-auto sm:w-[13rem] sm:border-b-0 sm:border-r sm:border-t">
          <div className="flex min-h-11 items-center justify-between px-3 py-1.5 sm:px-2">
            <DashboardBrandLink
              routerEnabled={routerEnabled}
              className="font-medium focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground sm:hidden"
            >
              {t("brand")}
            </DashboardBrandLink>
            <div className="flex min-w-0 items-center gap-1 sm:w-full">
              <button
                type="button"
                aria-controls="dashboard-mobile-nav"
                aria-expanded={mobileNavOpen}
                aria-label={mobileNavOpen ? common("closeMenu") : common("openMenu")}
                onClick={() => setMobileNavOpen((open) => !open)}
                className="inline-flex size-8 items-center justify-center text-muted hover:text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground sm:hidden"
              >
                <DashboardMenuIcon open={mobileNavOpen} />
              </button>
              {account}
            </div>
          </div>
          <DashboardNav
            id="dashboard-mobile-nav"
            groups={groups}
            routerEnabled={routerEnabled}
            hidden={!mobileNavOpen}
            onNavigate={() => setMobileNavOpen(false)}
            className="max-h-[calc(100vh-6rem)] overflow-y-auto border-t border-border px-2 py-3 sm:hidden"
          />
        </header>
        <main className="min-w-0">{children}</main>
      </div>
    </div>
  );
}

function normalizeDashboardPath(pathname: string) {
  const dashboardIndex = pathname.indexOf("/dashboard");
  if (dashboardIndex >= 0) return pathname.slice(dashboardIndex);
  if (pathname === "/") return "/dashboard";
  return `/dashboard${pathname.startsWith("/") ? pathname : `/${pathname}`}`;
}

function DashboardBrandLink({
  routerEnabled,
  className,
  children,
}: {
  routerEnabled: boolean;
  className: string;
  children: React.ReactNode;
}) {
  if (routerEnabled) {
    return <TanStackLink to="/" className={className}>{children}</TanStackLink>;
  }
  return <Link href="/dashboard" className={className}>{children}</Link>;
}

function DashboardNav({
  groups,
  className,
  hidden,
  id,
  onNavigate,
  routerEnabled,
}: {
  groups: DashboardNavGroup[];
  className?: string;
  hidden?: boolean;
  id?: string;
  onNavigate?: () => void;
  routerEnabled: boolean;
}) {
  return (
    <nav id={id} className={className} hidden={hidden}>
      <div className="space-y-4">
        {groups.map((group) => (
          <DashboardNavGroupView
            key={group.label}
            group={group}
            onNavigate={onNavigate}
            routerEnabled={routerEnabled}
          />
        ))}
      </div>
    </nav>
  );
}

export function DashboardNavGroupView({
  group,
  onNavigate,
  routerEnabled = false,
}: {
  group: DashboardNavGroup;
  onNavigate?: () => void;
  routerEnabled?: boolean;
}) {
  return (
    <div>
      <p className="px-2 text-[11px] font-semibold text-foreground">
        {group.label}
      </p>
      <div className="mt-1 space-y-0.5">
        {group.items.map((item) =>
          routerEnabled ? (
            <TanStackLink
              key={item.href}
              to={item.href.replace(/^\/dashboard/, "") || "/"}
              activeOptions={{ exact: item.href === "/dashboard" }}
              onClick={onNavigate}
              activeProps={{ "aria-current": "page" }}
              className={`block border-l px-2 py-1.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                item.active
                  ? "border-foreground bg-code-bg text-foreground"
                  : "border-transparent text-muted hover:border-border hover:text-foreground"
              }`}
            >
              {item.label}
            </TanStackLink>
          ) : (
            <Link
              key={item.href}
              href={item.href}
              onClick={onNavigate}
              aria-current={item.active ? "page" : undefined}
              className={`block border-l px-2 py-1.5 focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
                item.active
                  ? "border-foreground bg-code-bg text-foreground"
                  : "border-transparent text-muted hover:border-border hover:text-foreground"
              }`}
            >
              {item.label}
            </Link>
          )
        )}
      </div>
    </div>
  );
}

function DashboardMenuIcon({ open }: { open: boolean }) {
  return (
    <svg
      aria-hidden="true"
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinecap="round"
    >
      {open ? (
        <>
          <path d="M3 3l10 10" />
          <path d="M13 3L3 13" />
        </>
      ) : (
        <>
          <path d="M2.5 4h11" />
          <path d="M2.5 8h11" />
          <path d="M2.5 12h11" />
        </>
      )}
    </svg>
  );
}
