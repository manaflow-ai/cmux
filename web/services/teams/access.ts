import type { AuthedUser } from "../vms/auth";
import { teamErrorResponse, TeamServiceUnavailableError } from "./errors";
import {
  grantsByUser,
  roleFromGrants,
  STACK_PERMISSION_BY_NAME,
  viewerPermissionsFromGrants,
} from "./permissions";
import {
  defaultTeamStackApp,
  isStackTeamId,
  withStackDeadline,
  type StackTeam,
  type StackTeamMember,
  type TeamStackApp,
} from "./stack";
import type { TeamPermissionName, TeamRole, TeamViewerPermissions } from "./types";

/** A verified member's view of one team, loaded in three Stack calls. */
export type TeamAccess = {
  readonly userId: string;
  readonly team: StackTeam;
  readonly members: readonly StackTeamMember[];
  readonly grants: ReadonlyMap<string, ReadonlySet<string>>;
  readonly role: TeamRole;
  readonly permissions: TeamViewerPermissions;
};

export type TeamAccessRefusal =
  | { readonly code: "team_not_found"; readonly status: 403 }
  | { readonly code: "forbidden"; readonly status: 403; readonly permission: string }
  | { readonly code: "permission_unavailable"; readonly status: 503 };

export type TeamAccessResult =
  | { readonly ok: true; readonly access: TeamAccess }
  | { readonly ok: false; readonly refusal: TeamAccessRefusal; readonly response: Response };

export type TeamAccessOptions = {
  /** A viewer capability the caller must hold. */
  readonly permission?: TeamPermissionName;
  /** Require the admin role in addition to any permission. */
  readonly admin?: boolean;
  readonly stack?: TeamStackApp;
};

const TEAM_NOT_FOUND: TeamAccessRefusal = { code: "team_not_found", status: 403 };
const PERMISSION_UNAVAILABLE: TeamAccessRefusal = { code: "permission_unavailable", status: 503 };

/**
 * Authorize `user` against a real Stack team. Membership is read fresh from
 * Stack rather than from the session's team list, so a removed member is
 * refused at once. A non-member and a missing team get the same refusal, so
 * the route never reveals whether a team exists. Any Stack failure fails
 * closed as a retryable 503; it is never read as "no permission".
 */
export async function requireTeamAccess(
  user: Pick<AuthedUser, "id">,
  rawTeamId: string,
  options: TeamAccessOptions = {},
): Promise<TeamAccessResult> {
  const teamId = rawTeamId.trim();
  // The synthetic personal team is user-scoped billing, not a Stack team.
  if (!isStackTeamId(teamId) || teamId === user.id) return refuse(TEAM_NOT_FOUND);

  let access: TeamAccess | null;
  try {
    access = await loadTeamAccess(user.id, teamId, options.stack ?? defaultTeamStackApp());
  } catch (error) {
    if (!(error instanceof TeamServiceUnavailableError)) throw error;
    return refuse(PERMISSION_UNAVAILABLE);
  }
  if (!access) return refuse(TEAM_NOT_FOUND);

  if (options.admin && access.role !== "admin") {
    return refuse({ code: "forbidden", status: 403, permission: "team_admin" });
  }
  if (options.permission && !access.permissions[options.permission]) {
    return refuse({ code: "forbidden", status: 403, permission: permissionLabel(options.permission) });
  }
  return { ok: true, access };
}

/** Load a team, its members, and every member's recursive grants. */
export async function loadTeamAccess(
  userId: string,
  teamId: string,
  stack: TeamStackApp,
): Promise<TeamAccess | null> {
  const team = await withStackDeadline(() => stack.getTeam(teamId));
  if (!team) return null;
  const [members, rows] = await Promise.all([
    withStackDeadline(() => team.listUsers()),
    withStackDeadline(() => stack.listTeamMemberPermissions(teamId, { recursive: true })),
  ]);
  if (!members.some((member) => member.id === userId)) return null;
  const grants = grantsByUser(rows);
  const viewerGrants = grants.get(userId) ?? new Set<string>();
  return {
    userId,
    team,
    members,
    grants,
    role: roleFromGrants(viewerGrants),
    permissions: viewerPermissionsFromGrants(viewerGrants),
  };
}

/** The role Stack grants say a member holds. */
export function memberRole(access: Pick<TeamAccess, "grants">, userId: string): TeamRole {
  return roleFromGrants(access.grants.get(userId) ?? new Set());
}

export function adminCount(access: Pick<TeamAccess, "grants" | "members">): number {
  return access.members.filter((member) => memberRole(access, member.id) === "admin").length;
}

function permissionLabel(permission: TeamPermissionName): string {
  return permission === "manageBilling" ? "team_admin" : STACK_PERMISSION_BY_NAME[permission];
}

function refuse(refusal: TeamAccessRefusal): TeamAccessResult {
  const headers: Record<string, string> = refusal.code === "permission_unavailable"
    ? { "retry-after": "5" }
    : {};
  return {
    ok: false,
    refusal,
    response: teamErrorResponse(refusal.code, refusal.status, { headers }),
  };
}
