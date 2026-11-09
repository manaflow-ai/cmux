/// A Cloud start the platform refused because the acting team has no Cloud plan (`cloud_plan_required`,
/// from the reserve's bind, the start-chat CLI or the App's create). Leo, 2026-11-09, after his Cloud
/// chat failed with the company team picked in the team menu instead of his own account: "i guess is
/// team? it's kinda hard to realize tho". The card says which team it was and offers the person's own.
///
/// The host passes the teams as data (CloudStartChat `teams`: the active team's id, every team the
/// person may switch to, and who they are); which one is the person's own is decided here. The sign-in
/// service's teams carry no kind, so the person's own team is the one named for them: Stack Auth names
/// a person's own team "Personal Team" or "<name>'s Team", and some accounts name it by their email.

export type CloudPlanTeam = { id: string; name: string };

/// What the card shows for a plan refusal in a team: the team's name, and the person's own team to
/// switch to when there is one other than it. Undefined: the refusal was in the person's own account
/// (or the host named no team), so the card keeps the plan's own words.
export type CloudPlanTeamRefusal = { team: string; switchTo?: CloudPlanTeam };

type Details = {
  team?: unknown;
  teams?: unknown;
  canSwitch?: unknown;
  userName?: unknown;
  userEmail?: unknown;
};

function teamsOf(value: unknown): CloudPlanTeam[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    const { id, name } = (entry ?? {}) as { id?: unknown; name?: unknown };
    return typeof id === "string" && id && typeof name === "string" && name.trim() ? [{ id, name: name.trim() }] : [];
  });
}

const fold = (text: string) => text.trim().toLocaleLowerCase();

/// Whether `team` is named for the person: "Personal", "Personal Team", "<their name>'s Team", their
/// name or their email. A team named "<someone else>'s Team" is not theirs.
export function isOwnTeam(team: CloudPlanTeam, person: { name?: string; email?: string }): boolean {
  const name = fold(team.name);
  if (name === "personal" || name === "personal team") return true;
  const own = [person.name, person.email, person.email?.split("@")[0]].flatMap((word) =>
    word && word.trim() ? [fold(word)] : [],
  );
  return own.some((word) => name === word || name === `${word}'s team` || name === `${word}’s team`);
}

/// The card's team and switch for a `cloud_plan_required` answer's `details`, or undefined when the
/// refusal was not in a team (the person's own account, or no team named).
export function cloudPlanTeamRefusal(details: unknown): CloudPlanTeamRefusal | undefined {
  if (!details || typeof details !== "object") return undefined;
  const { team: activeId, teams: listed, canSwitch, userName, userEmail } = details as Details;
  const teams = teamsOf(listed);
  const active = teams.find((team) => team.id === activeId);
  if (!active) return undefined;
  const person = {
    ...(typeof userName === "string" ? { name: userName } : {}),
    ...(typeof userEmail === "string" ? { email: userEmail } : {}),
  };
  if (isOwnTeam(active, person)) return undefined;
  if (canSwitch === false) return { team: active.name };
  const others = teams.filter((team) => team.id !== active.id);
  // Their own team; with one other team only, that one (the account has no third to confuse it with).
  const own = others.find((team) => isOwnTeam(team, person)) ?? (others.length === 1 ? others[0] : undefined);
  return own ? { team: active.name, switchTo: own } : { team: active.name };
}
