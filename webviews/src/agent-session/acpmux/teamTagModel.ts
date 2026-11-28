/** The active team as the app reports it (`cloudMachine.list`'s and the Machines snapshot's `team`). */
export type ActiveTeamTag = { name: string; personal: boolean };

const teamTag = (value: unknown): ActiveTeamTag | undefined => {
  const team = value as { name?: unknown; personal?: unknown } | null | undefined;
  if (typeof team?.name !== "string") return undefined;
  const name = team.name.trim();
  return name ? { name, personal: team.personal === true } : undefined;
};

/** The `team` field of an app reply; undefined unless it names a team. With the reply's `teams`
 * (the account's team list as the team menu has it), only a team on that list: a team the account
 * was removed from, still named as the saved selection, falls back to the person's own team on the
 * list (the `personal` one), else no team. The tag never names a team the account is not in. */
export function activeTeamFromReply(value: unknown, teams?: unknown): ActiveTeamTag | undefined {
  const team = teamTag(value);
  if (!team || !Array.isArray(teams)) return team;
  // By id where the app names one (two teams may share a name), else by name.
  const idOf = (row: unknown) => {
    const id = (row as { id?: unknown } | null | undefined)?.id;
    return typeof id === "string" && id ? id : undefined;
  };
  const id = idOf(value);
  const rows = teams.filter((row) => teamTag(row) !== undefined);
  const same = (row: unknown) => (id && idOf(row) ? idOf(row) === id : teamTag(row)!.name === team.name);
  if (rows.some(same)) return team;
  return rows.map(teamTag).find((row) => row?.personal);
}

/** The icon a team row draws: `account` (a person) for the person's own team, `team` (people) otherwise. */
export const teamIconName = (team: ActiveTeamTag): "account" | "team" => (team.personal ? "account" : "team");
