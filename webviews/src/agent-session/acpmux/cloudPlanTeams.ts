/// A Cloud start the platform refused because the acting team has no Cloud plan (`cloud_plan_required`,
/// from the reserve's bind, the start-chat CLI or the App's create). Leo, 2026-11-09, after his Cloud
/// chat failed with the company team picked in the team menu instead of his own account: "i guess is
/// team? it's kinda hard to realize tho". The card says which team it was and offers the person's own.
///
/// The host passes the teams as data (CloudAuth `planRefusalTeams`: the active team's id and every
/// team the person may switch to). The person's own team is known by its id, never its name: the
/// platform's personal team id, `team_` and 20 lowercase hex digits (cmux-platform `personalTeamIdFor`),
/// which the team menu lists as its first row (cmux#39950). Stack's teams carry Stack's own ids, and
/// a Stack team named "Personal" is a legacy machine tenant, not the person's own team.
// TODO(cmux#39950): match the exact id from cmux-cloud-config `identity::personal_team_id`, passed by
// the host, once that helper lands.

export type CloudPlanTeam = { id: string; name: string };

/// What the card shows for a plan refusal in a team: the team's name, and the person's own team to
/// switch to when the team menu lists it. Undefined: the refusal was in the person's own account (or
/// the host named no team), so the card keeps the plan's own words.
export type CloudPlanTeamRefusal = { team: string; switchTo?: CloudPlanTeam };

const PERSONAL_TEAM_ID = /^team_[0-9a-f]{20}$/;

/// Whether `id` is the platform's personal team id (the form only the person's own team has here).
export function isPersonalTeamId(id: string): boolean {
  return PERSONAL_TEAM_ID.test(id);
}

function teamsOf(value: unknown): CloudPlanTeam[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    const { id, name } = (entry ?? {}) as { id?: unknown; name?: unknown };
    return typeof id === "string" && id && typeof name === "string" && name.trim() ? [{ id, name: name.trim() }] : [];
  });
}

/// The card's team and switch for a `cloud_plan_required` answer's `details`, or undefined when the
/// refusal was not in a team (the person's own account, or no team named).
export function cloudPlanTeamRefusal(details: unknown): CloudPlanTeamRefusal | undefined {
  if (!details || typeof details !== "object") return undefined;
  type Details = { team?: unknown; teams?: unknown; canSwitch?: unknown };
  const { team: activeId, teams: listed, canSwitch } = details as Details;
  const teams = teamsOf(listed);
  const active = teams.find((team) => team.id === activeId);
  if (!active || isPersonalTeamId(active.id)) return undefined;
  const own = canSwitch === false ? undefined : teams.find((team) => isPersonalTeamId(team.id));
  return own ? { team: active.name, switchTo: own } : { team: active.name };
}
