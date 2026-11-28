// The team cmux works in, where it changes what a pick does (the Cloud row of the environment
// picker, the Machines section's Cloud header; the composer chip's face says only Cloud): the
// team's name after a person icon for the person's own team, or a people icon for a shared one, in
// the secondary ink.
// The same icons the account menu and Switch Active Team draw on each team's row. Leo, 2026-11-09,
// of the account menu's team row: "i guess is team? it's kinda hard to realize tho".
import { Icon } from "./icons/Icon";
import { teamIconName, type ActiveTeamTag } from "./teamTagModel";

export function TeamTag({ team, size = 12 }: { team: ActiveTeamTag; size?: number }) {
  return (
    <span className="acpmux-team-tag" data-personal={team.personal ? "" : undefined}>
      <Icon name={teamIconName(team)} size={size} />
      <span className="acpmux-team-tag-name">{team.name}</span>
    </span>
  );
}
