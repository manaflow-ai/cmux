"use client";

import { useStackApp, useUser, type CurrentUser } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { usePathname } from "@/i18n/navigation";
import {
  SettingsSubnav,
  type SettingsSubnavGroup,
  type SettingsSubnavItem,
} from "../components/settings-ui";

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
  const item = (href: string, key: string, exact = false): SettingsSubnavItem => ({
    href,
    label: label(key),
    active: exact ? pathname === href : pathname === href || pathname.startsWith(`${href}/`),
  });
  const account: SettingsSubnavItem[] = [
    item("/dashboard/settings", "profile", true),
    item("/dashboard/settings/auth", "auth"),
    item("/dashboard/settings/notifications", "notifications"),
    item("/dashboard/settings/sessions", "sessions"),
    ...(allowUserApiKeys ? [item("/dashboard/settings/api-keys", "apiKeys")] : []),
    item("/dashboard/settings/account", "account"),
    item("/dashboard/billing", "billing"),
  ];
  const teamItems: SettingsSubnavItem[] = [
    ...teams.map((team) => {
      const href = `/dashboard/teams/${encodeURIComponent(team.id)}`;
      return {
        id: `team-${team.id}`,
        href,
        label: team.displayName,
        icon: <TeamInitial team={team} />,
        active: pathname === href || pathname.startsWith(`${href}/`),
      };
    }),
    item("/dashboard/teams/new", "createTeam"),
  ];
  return [
    { id: "account", items: account },
    { id: "teams", label: label("teamsGroup"), items: teamItems },
  ];
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
  const pathname = usePathname();
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
