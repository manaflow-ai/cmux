"use client";

import { useStackApp, useUser, type CurrentUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { type LinkOptions, useLocation } from "@tanstack/react-router";
import {
  SettingsSubnav,
  type SettingsSubnavGroup,
  type SettingsSubnavItem,
} from "@/dashboard-app/components/settings-ui";

export type SettingsNavTeam = {
  readonly id: string;
  readonly displayName: string;
  readonly profileImageUrl: string | null;
};

type SettingsNavOptions = {
  readonly pathname: string;
  readonly allowUserApiKeys: boolean;
  readonly teams: readonly SettingsNavTeam[];
  readonly label: (key: string) => string;
};

/** Build the settings navigation groups; exported for tests. */
export function settingsNavGroups({
  pathname,
  allowUserApiKeys,
  teams,
  label,
}: SettingsNavOptions): SettingsSubnavGroup[] {
  const item = (link: LinkOptions & { readonly to: string }, key: string, exact = false): SettingsSubnavItem => ({
    link: exact ? { ...link, activeOptions: { exact: true } } : link,
    label: label(key),
    active: exact ? pathname === link.to : isAtOrBelow(pathname, link.to),
  });
  const account: SettingsSubnavItem[] = [
    item({ to: "/dashboard/settings" }, "profile", true),
    item({ to: "/dashboard/settings/auth" }, "auth"),
    item({ to: "/dashboard/settings/notifications" }, "notifications"),
    item({ to: "/dashboard/settings/sessions" }, "sessions"),
    ...(allowUserApiKeys ? [item({ to: "/dashboard/settings/api-keys" }, "apiKeys")] : []),
    item({ to: "/dashboard/settings/account" }, "account"),
  ];
  const teamItems: SettingsSubnavItem[] = [
    ...teams.map((team) => ({
      id: `team-${team.id}`,
      link: { to: "/dashboard/teams/$teamId", params: { teamId: team.id } } satisfies LinkOptions,
      label: team.displayName,
      icon: <TeamInitial team={team} />,
      // Router pathnames are decoded, so compare against the raw id.
      active: isAtOrBelow(pathname, `/dashboard/teams/${team.id}`),
    })),
    item({ to: "/dashboard/teams/new" }, "createTeam"),
  ];
  return [
    { id: "account", label: label("accountGroup"), items: account },
    { id: "billing", label: label("billingGroup"), items: [item({ to: "/dashboard/billing" }, "planBilling")] },
    { id: "teams", label: label("teamsGroup"), items: teamItems },
  ];
}

function isAtOrBelow(pathname: string, path: string): boolean {
  return pathname === path || pathname.startsWith(`${path}/`);
}

/** Navigation without account data: the Suspense fallback. */
export function SettingsNav({
  allowUserApiKeys = false,
  teams = [],
}: {
  readonly allowUserApiKeys?: boolean;
  readonly teams?: readonly SettingsNavTeam[];
}) {
  const t = useTranslations("dashboard.settings.nav");
  const { pathname } = useLocation();
  return (
    <SettingsSubnav
      title={t("title")}
      groups={settingsNavGroups({ pathname, allowUserApiKeys, teams, label: (key) => t(key) })}
    />
  );
}

/** Navigation with the project's API key flag and the user's teams. */
export function SettingsNavWithAccount() {
  const project = useStackApp().useProject();
  const user = useUser({ or: "return-null" });
  if (!user) return <SettingsNav allowUserApiKeys={project.config.allowUserApiKeys} />;
  return <SettingsNavWithTeams user={user} allowUserApiKeys={project.config.allowUserApiKeys} />;
}

function SettingsNavWithTeams({
  user,
  allowUserApiKeys,
}: {
  readonly user: CurrentUser;
  readonly allowUserApiKeys: boolean;
}) {
  const teams = user.useTeams();
  return <SettingsNav allowUserApiKeys={allowUserApiKeys} teams={teams} />;
}

function TeamInitial({ team }: { readonly team: SettingsNavTeam }) {
  if (team.profileImageUrl) {
    return (
      // eslint-disable-next-line @next/next/no-img-element -- Stack stores team images as data URLs.
      <img src={team.profileImageUrl} alt="" className="size-4 object-cover" />
    );
  }
  return (
    <span
      aria-hidden="true"
      className="flex size-4 items-center justify-center bg-code-bg text-[10px] font-medium uppercase text-foreground"
    >
      {team.displayName.trim().charAt(0) || "?"}
    </span>
  );
}
