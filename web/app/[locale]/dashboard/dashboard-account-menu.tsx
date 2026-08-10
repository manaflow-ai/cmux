"use client";

import { Menu } from "@base-ui-components/react/menu";
import {
  TeamSwitcher,
  UserAvatar,
  useUser,
} from "@stackframe/stack";
import { useQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { useState } from "react";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import { Link, useRouter } from "@/i18n/navigation";

const menuItemClass =
  "flex min-h-9 w-full cursor-default select-none items-center gap-2 px-2.5 py-2 text-left text-sm text-foreground no-underline outline-none data-[highlighted]:bg-code-bg";

export function DashboardAccountMenu() {
  const t = useTranslations("dashboard.accountMenu");
  const nav = useTranslations("dashboard.nav");
  const locale = useLocale();
  const router = useRouter();
  const user = useUser({ or: "return-null" });
  const [signOutPending, setSignOutPending] = useState(false);
  const [signOutError, setSignOutError] = useState(false);
  const signInHref = vaultSignInHref(localizedVaultPath(locale, "/dashboard"));

  if (!user) {
    return (
      <a
        href={signInHref}
        aria-label={t("signIn")}
        className="flex min-w-0 flex-1 items-center gap-2.5 px-1.5 py-1 text-muted hover:bg-code-bg hover:text-foreground"
      >
        <UserAvatar size={24} user={null} />
        <span className="hidden truncate font-medium sm:block">{t("signIn")}</span>
      </a>
    );
  }

  return (
    <Menu.Root>
      <Menu.Trigger
        className="flex min-w-0 flex-1 items-center gap-2.5 px-1.5 py-1 text-left outline-none hover:bg-code-bg focus-visible:bg-code-bg"
        aria-label={t("label")}
      >
        <UserAvatar size={24} user={user} />
        <span className="hidden min-w-0 flex-1 truncate font-medium sm:block">
          {user.displayName || user.primaryEmail}
        </span>
        <ChevronsUpDown />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner side="top" align="start" sideOffset={8} className="z-50">
          <Menu.Popup className="w-52 border border-border bg-background p-1 text-foreground shadow-xl shadow-black/10 outline-none">
            <div className="border-b border-border px-2.5 py-2">
              <div className="truncate text-sm font-medium">
                {user.displayName || user.primaryEmail}
              </div>
              {user.displayName ? (
                <div className="truncate text-xs text-muted">{user.primaryEmail}</div>
              ) : null}
            </div>
            <div className="border-b border-border px-2.5 py-2">
              <div className="mb-1.5 text-[11px] font-medium uppercase tracking-wide text-muted">
                {nav("team")}
              </div>
              <DashboardOrganizationSwitcher />
            </div>
            <Menu.Item render={<Link href="/dashboard/team" />} className={menuItemClass}>
              <SettingsIcon />
              <span>{t("settings")}</span>
            </Menu.Item>
            <Menu.Item render={<Link href="/dashboard/billing" />} className={menuItemClass}>
              <BillingIcon />
              <span>{t("billing")}</span>
            </Menu.Item>
            <Menu.Separator className="mx-1 my-1 h-px bg-border" />
            <Menu.Item
              className={`${menuItemClass} text-red-600 dark:text-red-400`}
              disabled={signOutPending}
              onClick={async (event) => {
                event.preventDefault();
                if (signOutPending) return;
                setSignOutPending(true);
                setSignOutError(false);
                try {
                  await user.signOut();
                  router.replace("/");
                  router.refresh();
                } catch {
                  setSignOutPending(false);
                  setSignOutError(true);
                }
              }}
            >
              <SignOutIcon />
              <span>{signOutPending ? t("signingOut") : t("signOut")}</span>
            </Menu.Item>
            {signOutError ? (
              <p role="alert" className="px-2.5 py-1.5 text-xs text-red-600 dark:text-red-400">
                {t("signOutError")}
              </p>
            ) : null}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}

type OrganizationCatalog = {
  readonly selectedTeamId: string | null;
  readonly teams: readonly {
    readonly id: string;
    readonly name: string;
    readonly personal: boolean;
  }[];
};

function DashboardOrganizationSwitcher() {
  const user = useUser({ or: "throw" });
  const teams = user.useTeams();
  const router = useRouter();
  const t = useTranslations("dashboard.accountMenu");
  const [selectedOrganizationId, setSelectedOrganizationId] = useState<
    string | undefined
  >(undefined);
  const { data, isPending } = useQuery({
    queryKey: ["coderouter-organizations"],
    queryFn: loadOrganizationCatalog,
    staleTime: 60_000,
  });

  if (isPending) {
    return <div aria-hidden="true" className="h-9 w-full animate-pulse bg-code-bg" />;
  }
  if (!data) {
    return (
      <Link
        href="/dashboard/team"
        className="block min-h-9 border border-border px-2 py-2 text-sm text-muted hover:bg-code-bg hover:text-foreground"
      >
        {t("settings")}
      </Link>
    );
  }

  const authorizedIds = new Set(data.teams.map((team) => team.id));
  const selectableTeams = teams.filter((team) => authorizedIds.has(team.id));
  const personal = data.teams.find((team) => team.personal);
  const selectedTeamId = selectedOrganizationId ??
    (user.selectedTeam && authorizedIds.has(user.selectedTeam.id)
      ? user.selectedTeam.id
      : data.selectedTeamId ?? data.teams[0]?.id);
  const switchOrganization = async (
    team: (typeof selectableTeams)[number] | null,
  ) => {
    const organizationId = team?.id ?? personal?.id;
    if (!organizationId) return;
    await user.setSelectedTeam(team);
    setSelectedOrganizationId(organizationId);
    router.push(
      `/dashboard/coderouter?team=${
        encodeURIComponent(organizationId)
      }`,
    );
    router.refresh();
  };
  const shared = {
    teams: selectableTeams,
    teamId: personal?.id === selectedTeamId ? undefined : selectedTeamId,
    triggerClassName:
      "min-h-9 w-full border border-border bg-background px-2 text-left text-sm hover:bg-code-bg",
  };

  return personal
    ? (
      <TeamSwitcher
        {...shared}
        allowNull
        nullLabel={personal.name}
        onChange={switchOrganization}
      />
    )
    : <TeamSwitcher {...shared} onChange={switchOrganization} />;
}

async function loadOrganizationCatalog(): Promise<OrganizationCatalog> {
  const response = await fetch("/api/coderouter/organizations", {
    headers: { accept: "application/json" },
  });
  if (!response.ok) {
    throw new Error("Could not load CodeRouter organizations");
  }
  const body: unknown = await response.json();
  if (
    typeof body !== "object" ||
    body === null ||
    !("teams" in body) ||
    !Array.isArray(body.teams)
  ) {
    throw new Error("Invalid CodeRouter organization response");
  }
  return body as OrganizationCatalog;
}

function ChevronsUpDown() {
  return (
    <svg
      aria-hidden="true"
      className="hidden size-3.5 shrink-0 text-muted sm:block"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="m5 6 3-3 3 3" />
      <path d="m5 10 3 3 3-3" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <circle cx="8" cy="8" r="2.25" />
      <path d="M8 1.75v1.5M8 12.75v1.5M1.75 8h1.5M12.75 8h1.5M3.6 3.6l1.05 1.05M11.35 11.35l1.05 1.05M12.4 3.6l-1.05 1.05M4.65 11.35 3.6 12.4" />
    </svg>
  );
}

function BillingIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <rect x="1.75" y="3.25" width="12.5" height="9.5" />
      <path d="M1.75 6h12.5M4 10h2.5" />
    </svg>
  );
}

function SignOutIcon() {
  return (
    <svg aria-hidden="true" className="size-4" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25">
      <path d="M6.75 2.25h-3.5v11.5h3.5M9.25 5l3 3-3 3M12 8H6" />
    </svg>
  );
}
