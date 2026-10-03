// What the DEBUG `debug.agent_pane` chat actions act on: the pending permission an
// `answer_permission` answers, and the turn whose changes `open_changes` opens. Pure, so the
// choices are tested without a page; debug.ts calls the pane's own paths with them.
import { turnFiles } from "./diff";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import type { PermissionDecision } from "./permissions/protocol";

/// `allow` and `deny` pick the matching option of a single request; a group also takes its own
/// decisions (`allow_once`, `allow_chat`, `deny`). `allow` on a group is `allow_once`.
export type DebugDecision = "allow" | "deny" | PermissionDecision;

export type DebugAnswer =
  | { kind: "permission"; permissionId: string; optionId: string }
  | { kind: "group"; groupId: string; revision: number; decision: PermissionDecision }
  | { error: string; pending?: string[] };

/// The answer for `permission_id` (or `group_id`), or else the newest pending request: a single
/// request takes `option_id` or the first option that allows (or denies); a group takes the
/// decision when it offers it.
export function debugAnswer(
  snapshot: Pick<AcpmuxSnapshot, "rows" | "permissionGroups">,
  options: { permission_id?: string; group_id?: string; option_id?: string; decision?: DebugDecision },
): DebugAnswer {
  const decision = options.decision ?? "allow";
  const singles = snapshot.rows.flatMap((row) =>
    row.kind === "permission" && row.permission?.pending && !row.permission.groupId ? [row.permission] : [],
  );
  const groups = (snapshot.permissionGroups?.groups ?? []).filter((group) => group.state === "pending");
  const pending = [...singles.map((permission) => permission.permissionId), ...groups.map((group) => group.groupId)];
  const group = options.group_id
    ? groups.find((candidate) => candidate.groupId === options.group_id)
    : options.permission_id
      ? undefined
      : singles.length
        ? undefined
        : groups.at(-1);
  if (group || options.group_id) {
    if (!group) return { error: `no pending permission group ${options.group_id}`, pending };
    const wanted: PermissionDecision = decision === "allow" ? "allow_once" : decision;
    if (!group.decisions.includes(wanted))
      return { error: `the group offers ${group.decisions.join(", ")}, not ${wanted}`, pending };
    return { kind: "group", groupId: group.groupId, revision: group.revision, decision: wanted };
  }
  const permission = options.permission_id
    ? singles.find((candidate) => candidate.permissionId === options.permission_id)
    : singles.at(-1);
  if (!permission)
    return {
      error: options.permission_id ? `no pending permission ${options.permission_id}` : "no pending permission",
      pending,
    };
  const allow = decision !== "deny";
  const option = options.option_id
    ? permission.options.find((candidate) => candidate.id === options.option_id)
    : permission.options.find((candidate) => candidate.allow === allow);
  if (!option)
    return {
      error: options.option_id
        ? `permission ${permission.permissionId} has no option ${options.option_id}`
        : `permission ${permission.permissionId} has no ${allow ? "allow" : "deny"} option`,
      pending,
    };
  return { kind: "permission", permissionId: permission.permissionId, optionId: option.id };
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
