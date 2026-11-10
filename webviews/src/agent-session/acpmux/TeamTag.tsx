// The team cmux works in, where it changes what a pick does (the Cloud row of the environment
// picker, the composer's Cloud face, the Machines section's Cloud header): the team's name after a
// person icon for the person's own team, or a people icon for a shared one, in the secondary ink.
// The same icons the account menu and Switch Active Team draw on each team's row. Leo, 2026-11-09,
// of the account menu's team row: "i guess is team? it's kinda hard to realize tho".
import { Icon } from "./icons/Icon";

/** The active team as the app reports it (`cloudMachine.list`'s and the Machines snapshot's `team`). */
export type ActiveTeamTag = { name: string; personal: boolean };

/** The `team` field of an app reply; undefined unless it names a team. */
export function activeTeamFromReply(value: unknown): ActiveTeamTag | undefined {
  const team = value as { name?: unknown; personal?: unknown } | null | undefined;
  if (typeof team?.name !== "string") return undefined;
  const name = team.name.trim();
  return name ? { name, personal: team.personal === true } : undefined;
}

/** The icon a team row draws: `account` (a person) for the person's own team, `team` (people) otherwise. */
export const teamIconName = (team: ActiveTeamTag): "account" | "team" => (team.personal ? "account" : "team");

export function TeamTag({ team, size = 12 }: { team: ActiveTeamTag; size?: number }) {
  return (
    <span className="acpmux-team-tag" data-personal={team.personal ? "" : undefined} title={team.name}>
      <Icon name={teamIconName(team)} size={size} />
      <span className="acpmux-team-tag-name">{team.name}</span>
    </span>
  );
}

/// A Cloud pick's accessible name and tooltip with the team it runs in ("Cloud · cmux"), as its face shows.
export function withTeam(value: string, team: ActiveTeamTag | undefined): string {
  return team ? `${value} · ${team.name}` : value;
}
