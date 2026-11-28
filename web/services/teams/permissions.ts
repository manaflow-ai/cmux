import type { TeamPermissionName, TeamRole, TeamViewerPermissions } from "./types";

/** The Stack team permission that makes a member an admin. */
export const TEAM_ADMIN_PERMISSION = "team_admin";

/** Stack system permissions behind each viewer capability, except billing. */
export const STACK_PERMISSION_BY_NAME = {
  updateTeam: "$update_team",
  deleteTeam: "$delete_team",
  inviteMembers: "$invite_members",
  readMembers: "$read_members",
  removeMembers: "$remove_members",
  manageApiKeys: "$manage_api_keys",
} as const satisfies Record<Exclude<TeamPermissionName, "manageBilling">, string>;

/** Map a member's recursive Stack grants onto the role cmux shows. */
export function roleFromGrants(grants: ReadonlySet<string>): TeamRole {
  return grants.has(TEAM_ADMIN_PERMISSION) ? "admin" : "member";
}

/** Billing is ours, not a Stack permission: only admins manage it. */
export function viewerPermissionsFromGrants(grants: ReadonlySet<string>): TeamViewerPermissions {
  return {
    updateTeam: grants.has(STACK_PERMISSION_BY_NAME.updateTeam),
    deleteTeam: grants.has(STACK_PERMISSION_BY_NAME.deleteTeam),
    inviteMembers: grants.has(STACK_PERMISSION_BY_NAME.inviteMembers),
    readMembers: grants.has(STACK_PERMISSION_BY_NAME.readMembers),
    removeMembers: grants.has(STACK_PERMISSION_BY_NAME.removeMembers),
    manageApiKeys: grants.has(STACK_PERMISSION_BY_NAME.manageApiKeys),
    manageBilling: roleFromGrants(grants) === "admin",
  };
}

/** Group `listTeamMemberPermissions` rows by user. */
export function grantsByUser(
  rows: readonly { readonly userId: string; readonly permissionId: string }[],
): Map<string, Set<string>> {
  const byUser = new Map<string, Set<string>>();
  for (const row of rows) {
    const grants = byUser.get(row.userId) ?? new Set<string>();
    grants.add(row.permissionId);
    byUser.set(row.userId, grants);
  }
  return byUser;
}
