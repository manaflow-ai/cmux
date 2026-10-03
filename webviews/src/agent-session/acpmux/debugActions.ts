// What the DEBUG `debug.agent_pane` chat actions act on: the pending permission an
// `answer_permission` answers (the one the card shows), and the turn whose changes
// `open_changes` opens. Pure, so the choices are tested without a page; debug.ts calls the
// pane's own paths with them.
import { turnFiles } from "./diff";
import type { AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { permissionKeys, permissionOption } from "./permissionKeys";
import type { PermissionDecision } from "./permissions/protocol";

/// `allow` and `deny` answer a single request as its card's y and n keys do (once, never an
/// "always" option); a group also takes its own decisions (`allow_once`, `allow_chat`, `deny`),
/// and `allow` on a group is `allow_once`.
export type DebugDecision = "allow" | "deny" | PermissionDecision;

export type DebugAnswer =
  | { kind: "permission"; permissionId: string; optionId: string }
  | { kind: "group"; groupId: string; revision: number; decision: PermissionDecision }
  | { error: string; pending?: string[] };

/// The single request the permission card shows: pending, and not one the grouped panel
/// answers. App.tsx draws its card from this, so the debug action answers the same request.
export function cardPermission(
  snapshot: Pick<AcpmuxSnapshot, "permission" | "permissionGroups">,
): AcpmuxPermission | undefined {
  const permission = snapshot.permission;
  return permission?.pending && !(snapshot.permissionGroups?.supported && permission.groupId) ? permission : undefined;
}

/// The answer for `permission_id` (or `group_id`), or else the card's request, or else the newest
/// pending group. A single request takes `option_id`, or the option its card's y (allow) or n
/// (deny) key would; a group takes the decision when it offers it.
export function debugAnswer(
  snapshot: Pick<AcpmuxSnapshot, "permission" | "permissionGroups">,
  options: { permission_id?: string; group_id?: string; option_id?: string; decision?: DebugDecision },
): DebugAnswer {
  const decision = options.decision ?? "allow";
  const single = cardPermission(snapshot);
  const groups = snapshot.permissionGroups?.supported
    ? snapshot.permissionGroups.groups.filter((group) => group.state === "pending")
    : [];
  const pending = [...(single ? [single.permissionId] : []), ...groups.map((group) => group.groupId)];
  const wantsGroup = options.group_id !== undefined || (!options.permission_id && !single && groups.length > 0);
  if (wantsGroup) {
    const group = options.group_id ? groups.find((candidate) => candidate.groupId === options.group_id) : groups.at(-1);
    if (!group) return { error: `no pending permission group ${options.group_id}`, pending };
    const wanted: PermissionDecision = decision === "allow" ? "allow_once" : decision;
    if (!group.decisions.includes(wanted))
      return { error: `the group offers ${group.decisions.join(", ")}, not ${wanted}`, pending };
    return { kind: "group", groupId: group.groupId, revision: group.revision, decision: wanted };
  }
  if (!single || (options.permission_id && single.permissionId !== options.permission_id))
    return {
      error: options.permission_id ? `no pending permission ${options.permission_id}` : "no pending permission",
      pending,
    };
  if (decision !== "allow" && decision !== "deny" && !options.option_id)
    return { error: `${decision} answers a group; a single request takes allow, deny or option_id`, pending };
  const option = options.option_id
    ? single.options.find((candidate) => candidate.id === options.option_id)
    : permissionOption(single.options, permissionKeys(single.options), decision === "deny" ? "n" : "y");
  if (!option)
    return {
      error: options.option_id
        ? `permission ${single.permissionId} has no option ${options.option_id}`
        : `permission ${single.permissionId} has no ${decision === "deny" ? "deny" : "allow"}-once option; pass option_id (${single.options.map((candidate) => candidate.id).join(", ")})`,
      pending,
    };
  return { kind: "permission", permissionId: single.permissionId, optionId: option.id };
}

/// The row whose turn `open_changes` opens: `row_id` when given, else the newest activity row
/// that changed files, as the edited-files card under that turn would.
export function debugChangesRow(rows: readonly AcpmuxRow[], rowId?: string): AcpmuxRow | undefined {
  if (rowId) return rows.find((row) => row.id === rowId);
  for (let index = rows.length - 1; index >= 0; index--) {
    const row = rows[index]!;
    if (row.kind === "activity" && turnFiles([row]).length) return row;
  }
  return undefined;
}
