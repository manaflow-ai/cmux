import { isLastAdmin, type TeamDetail, type TeamMember } from "@/dashboard-app/queries/teams";

export type MemberActionId = "makeAdmin" | "makeMember" | "remove" | "leave";

export type MemberAction = {
  readonly id: MemberActionId;
  /** Why the action is shown but unavailable. */
  readonly disabledReason?: "lastAdmin";
};

/**
 * The actions menu of one member row. Admins change roles and remove others
 * (with `$remove_members`); everyone can leave from their own row. The only
 * admin still sees demote and leave, disabled with the reason, so the rule is
 * visible instead of failing after the click.
 */
export function memberActions(detail: TeamDetail, member: TeamMember): MemberAction[] {
  const viewerIsAdmin = detail.viewer.role === "admin";
  if (member.isViewer) {
    const lastAdmin = isLastAdmin(detail);
    const blocked = lastAdmin ? { disabledReason: "lastAdmin" as const } : {};
    return [
      ...(viewerIsAdmin ? [{ id: "makeMember" as const, ...blocked }] : []),
      { id: "leave", ...blocked },
    ];
  }
  if (!viewerIsAdmin) return [];
  return [
    { id: member.role === "admin" ? "makeMember" : "makeAdmin" },
    ...(detail.viewer.permissions.removeMembers ? [{ id: "remove" as const }] : []),
  ];
}
