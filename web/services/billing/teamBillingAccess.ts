import { Effect } from "effect";

/** Stack Auth's built-in team administrator permission. Admins manage billing. */
export const TEAM_ADMIN_PERMISSION = "team_admin";

const TEAM_AUTHORIZATION_TIMEOUT = "10 seconds";

export type TeamBillingRole = "admin" | "member";

export type TeamBillingAccessError =
  | "personal_team_not_upgradable_to_team"
  | "team_not_found"
  | "team_admin_required"
  | "authorization_unavailable";

/** The subset of a Stack team that billing reads. */
export type TeamBillingStackTeam = {
  readonly id: string;
  readonly displayName?: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  listUsers?(): Promise<readonly unknown[]>;
};

/**
 * The subset of a Stack server user that billing authorization needs. Method
 * syntax keeps parameters bivariant, so a real Stack `ServerUser` (whose
 * methods take the SDK `Team`) satisfies this shape.
 */
export type TeamBillingAccessUser = {
  readonly id: string;
  readonly selectedTeam?: TeamBillingStackTeam | null;
  getTeam?(teamId: string): Promise<TeamBillingStackTeam | null>;
  listTeams?(): Promise<readonly TeamBillingStackTeam[]>;
  hasPermission?(team: TeamBillingStackTeam, permissionId: string): Promise<boolean>;
};

export type TeamBillingAccess =
  | {
    readonly ok: true;
    readonly team: TeamBillingStackTeam;
    readonly role: TeamBillingRole;
    readonly canManageBilling: boolean;
  }
  | { readonly ok: false; readonly error: TeamBillingAccessError };

/**
 * Explicit-team billing authorization. The caller must be a member of
 * `teamId`; with `requireAdmin` they must also hold Stack `team_admin`. The
 * synthetic personal team (`teamId === user.id`) is never a Team billing
 * subject: personal plans are user-scoped and route to Pro/Max checkout.
 * Stack failures and timeouts fail closed as `authorization_unavailable`.
 */
export async function resolveTeamBillingAccess(
  user: TeamBillingAccessUser,
  rawTeamId: string,
  options: { readonly requireAdmin: boolean },
): Promise<TeamBillingAccess> {
  const teamId = rawTeamId.trim();
  if (!teamId) return { ok: false, error: "team_not_found" };
  if (teamId === user.id) return { ok: false, error: "personal_team_not_upgradable_to_team" };

  const lookup = await Effect.runPromise(Effect.tryPromise(async () => {
    const team = await memberTeam(user, teamId);
    if (!team) return null;
    return { team, isAdmin: await holdsTeamAdmin(user, team) };
  }).pipe(Effect.timeout(TEAM_AUTHORIZATION_TIMEOUT), Effect.either));

  if (lookup._tag === "Left") return { ok: false, error: "authorization_unavailable" };
  if (!lookup.right) return { ok: false, error: "team_not_found" };
  const { team, isAdmin } = lookup.right;
  if (options.requireAdmin && !isAdmin) return { ok: false, error: "team_admin_required" };
  return {
    ok: true,
    team,
    role: isAdmin ? "admin" : "member",
    canManageBilling: isAdmin,
  };
}

/** HTTP status for an explicit-team billing refusal. */
export function teamBillingAccessStatus(error: TeamBillingAccessError): 400 | 403 | 404 | 503 {
  switch (error) {
    case "personal_team_not_upgradable_to_team":
      return 400;
    case "team_admin_required":
      return 403;
    case "team_not_found":
      return 404;
    case "authorization_unavailable":
      return 503;
  }
}

/** Blank or missing means "no explicit team" (legacy implicit resolution). */
export function explicitTeamId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= 200 ? trimmed : null;
}

async function memberTeam(
  user: TeamBillingAccessUser,
  teamId: string,
): Promise<TeamBillingStackTeam | null> {
  // Stack only selects a team the user belongs to.
  if (user.selectedTeam?.id === teamId) return user.selectedTeam;
  if (typeof user.getTeam === "function") {
    const team = await user.getTeam(teamId);
    return team?.id === teamId ? team : null;
  }
  const teams = typeof user.listTeams === "function" ? await user.listTeams() : [];
  return teams.find((team) => team.id === teamId) ?? null;
}

async function holdsTeamAdmin(
  user: TeamBillingAccessUser,
  team: TeamBillingStackTeam,
): Promise<boolean> {
  if (typeof user.hasPermission !== "function") return false;
  return user.hasPermission(team, TEAM_ADMIN_PERMISSION);
}

/**
 * Role lookup that never throws: used by read-only listings (the dashboard
 * team catalog) where a Stack stall must degrade to "member" instead of
 * failing the whole listing. Mutations use resolveTeamBillingAccess.
 */
export async function teamBillingRoleOrMember(
  user: TeamBillingAccessUser,
  team: TeamBillingStackTeam,
): Promise<TeamBillingRole> {
  const result = await Effect.runPromise(Effect.tryPromise(() => holdsTeamAdmin(user, team))
    .pipe(Effect.timeout(TEAM_AUTHORIZATION_TIMEOUT), Effect.either));
  return result._tag === "Right" && result.right ? "admin" : "member";
}
