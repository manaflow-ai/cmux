import { Effect } from "effect";

/** Stack Auth's built-in team administrator permission. Admins manage billing. */
export const TEAM_ADMIN_PERMISSION = "team_admin";

const TEAM_AUTHORIZATION_TIMEOUT = "10 seconds";

export type TeamBillingRole = "admin" | "member";

export type TeamBillingAccessError =
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
  readonly displayName?: string | null;
  readonly primaryEmail?: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  readonly selectedTeam?: TeamBillingStackTeam | null;
  getTeam?(teamId: string): Promise<TeamBillingStackTeam | null>;
  listTeams?(): Promise<readonly TeamBillingStackTeam[]>;
  hasPermission?(team: TeamBillingStackTeam, permissionId: string): Promise<boolean>;
};

/** Metadata keys used when the synthetic personal scope owns a Team plan. */
export const PERSONAL_TEAM_PLAN_METADATA_KEY = "cmuxTeamPlan";
export const PERSONAL_TEAM_SEATS_METADATA_KEY = "cmuxTeamSeats";
export const PERSONAL_TEAM_VM_PLAN_METADATA_KEY = "cmuxTeamVmPlan";

function metadataRecord(raw: unknown): Record<string, unknown> {
  return raw && typeof raw === "object" && !Array.isArray(raw)
    ? { ...(raw as Record<string, unknown>) }
    : {};
}

export function personalTeamPlanIdFromMetadata(raw: unknown): string | null {
  const value = metadataRecord(raw)[PERSONAL_TEAM_PLAN_METADATA_KEY];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

export function personalTeamSeatsFromMetadata(raw: unknown): number | null {
  const value = metadataRecord(raw)[PERSONAL_TEAM_SEATS_METADATA_KEY];
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : null;
}

/** Make user metadata look like a team metadata object to shared billing code. */
function personalTeamMetadata(raw: unknown): Record<string, unknown> {
  const source = metadataRecord(raw);
  const team: Record<string, unknown> = {};
  const plan = personalTeamPlanIdFromMetadata(source);
  const seats = personalTeamSeatsFromMetadata(source);
  const vmPlan = source[PERSONAL_TEAM_VM_PLAN_METADATA_KEY];
  if (plan) team.cmuxPlan = plan;
  if (seats !== null) team.cmuxSeats = seats;
  if (typeof vmPlan === "string" && vmPlan.trim()) team.cmuxVmPlan = vmPlan.trim();
  return team;
}

/**
 * The dashboard's personal entry is not a Stack Team. Billing still needs a
 * team-shaped subject so Stripe metadata, checkout completion, plan reads and
 * seat reconciliation can use the same team-scoped paths. It starts with one
 * seat; inviting members remains a real-team operation.
 */
type PersonalTeamUser = TeamBillingAccessUser & {
  update?(options: { readonly clientReadOnlyMetadata: unknown }): Promise<unknown>;
};

export function personalTeamForUser(user: TeamBillingAccessUser): TeamBillingStackTeam & {
  update(options: { readonly clientReadOnlyMetadata: unknown }): Promise<unknown>;
} {
  const writableUser = user as PersonalTeamUser;
  let sourceMetadata = metadataRecord(user.clientReadOnlyMetadata);
  return {
    id: user.id,
    displayName: user.displayName ?? user.primaryEmail ?? user.id,
    get clientReadOnlyMetadata() {
      return personalTeamMetadata(sourceMetadata);
    },
    listUsers: async () => [{ id: user.id }],
    update: async ({ clientReadOnlyMetadata }) => {
      const teamMetadata = metadataRecord(clientReadOnlyMetadata);
      const next = { ...sourceMetadata };
      const plan = teamMetadata.cmuxPlan;
      const seats = teamMetadata.cmuxSeats;
      const vmPlan = teamMetadata.cmuxVmPlan;
      if (typeof plan === "string" && plan.trim()) next[PERSONAL_TEAM_PLAN_METADATA_KEY] = plan.trim();
      else delete next[PERSONAL_TEAM_PLAN_METADATA_KEY];
      if (typeof seats === "number" && Number.isSafeInteger(seats) && seats > 0) next[PERSONAL_TEAM_SEATS_METADATA_KEY] = seats;
      else delete next[PERSONAL_TEAM_SEATS_METADATA_KEY];
      if (typeof vmPlan === "string" && vmPlan.trim()) next[PERSONAL_TEAM_VM_PLAN_METADATA_KEY] = vmPlan.trim();
      else delete next[PERSONAL_TEAM_VM_PLAN_METADATA_KEY];
      sourceMetadata = next;
      if (typeof writableUser.update !== "function") throw new Error("Stack user cannot update Team metadata");
      return writableUser.update({ clientReadOnlyMetadata: next });
    },
  };
}

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
 * synthetic personal team (`teamId === user.id`) is a one-seat Team billing
 * subject. Its metadata is kept separate from personal Pro/Max.
 * Stack failures and timeouts fail closed as `authorization_unavailable`.
 */
export async function resolveTeamBillingAccess(
  user: TeamBillingAccessUser,
  rawTeamId: string,
  options: { readonly requireAdmin: boolean },
): Promise<TeamBillingAccess> {
  const teamId = rawTeamId.trim();
  if (!teamId) return { ok: false, error: "team_not_found" };
  const lookup = await Effect.runPromise(Effect.tryPromise(async () => {
    if (teamId === user.id) return { team: personalTeamForUser(user), isAdmin: true };
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
export function teamBillingAccessStatus(error: TeamBillingAccessError): 403 | 404 | 503 {
  switch (error) {
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
