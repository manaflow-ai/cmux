// The machine kind a cmux Cloud guest records in /etc/cmux/vm-kind.
//
// cmux-tui on the machine refuses to start or receive a chat on a Cloud VM
// unless that root-owned record reads `owner` (cmux-tui agent_start_host.rs,
// "a remote start is refused on a team VM, and on a Cloud VM whose kind the
// daemon cannot tell"). The guest's root-run cmux-vm-kind-sync asks
// GET /api/vm/reflection/kind and writes the answer; nothing the guest claims
// is an input here. The answer comes from the machine's own row, identified by
// the platform edge (services/vms/vmPrincipal.ts).
//
// - `owner`: exactly one person can reach the machine, its creator. That is a
//   machine on the creator's own account (owner_team_id is the creator's
//   user id, the synthetic personal team), or a machine of a Stack team whose
//   only member is the creator.
// - `team`: anyone else can, or might: a team with any other member, a team
//   the creator has left, or a team that no longer exists.
// - unknown (null): the member list could not be read. The route answers a
//   retryable 503 and the guest keeps whatever it wrote last.
//
// Team membership changes, so the kind is not fixed at create: the guest
// re-asks every minute and a machine whose team gains a member turns `team`
// on its next answer.
import type { VmTeamMemberLookup } from "./teamDirectory";
import type { VmPrincipalRow } from "./vmPrincipalContract";

export type VmGuestKind = "owner" | "team";

/** The row facts the kind depends on. */
export type VmGuestKindRow = Pick<VmPrincipalRow, "userId" | "ownerTeamId">;

/** True when the machine belongs to its creator's own account, with no Stack team to ask. */
export function vmIsOnPersonalAccount(row: VmGuestKindRow): boolean {
  const owner = row.ownerTeamId.trim();
  return owner !== "" && owner === row.userId.trim();
}

/**
 * The kind for a machine on a Stack team, from that team's member list. Null
 * when the list could not be read (fail closed: never `owner` on an error).
 */
export function vmGuestKindFromMembers(row: VmGuestKindRow, lookup: VmTeamMemberLookup): VmGuestKind | null {
  if ("error" in lookup) return null;
  // A missing team is nobody's personal machine.
  if (lookup.memberIds === null) return "team";
  const creator = row.userId.trim();
  const members = new Set(lookup.memberIds.map((id) => id.trim()));
  return creator !== "" && members.size === 1 && members.has(creator) ? "owner" : "team";
}

export type VmGuestKindDependencies = {
  /** A bounded member lookup (listTeamMemberIdsWithTimeout over the Stack directory). */
  readonly listMembers: (teamId: string) => Promise<VmTeamMemberLookup>;
};

/** The machine's kind, asking Stack only for a team-owned machine. */
export async function resolveVmGuestKind(
  row: VmGuestKindRow,
  dependencies: VmGuestKindDependencies,
): Promise<VmGuestKind | null> {
  if (vmIsOnPersonalAccount(row)) return "owner";
  const teamId = row.ownerTeamId.trim();
  if (!teamId) return null;
  return vmGuestKindFromMembers(row, await dependencies.listMembers(teamId));
}

/**
 * The facts vmKindForCaller reads besides the row. `chatGranted`: the caller
 * holds a chat grant on this machine (cloud_vm_chat_grants), read for this
 * attach; false or absent when it was not read or the read failed.
 */
export type VmKindForCallerOptions = { readonly chatGranted?: boolean };

/**
 * The kind the attach endpoint tells the signed-in caller (`vmKind`). The Mac
 * app gives up the local sandbox for its own session only on `owner`: the
 * caller created the machine and still belongs to its owner team, regardless
 * of that team's member count. Personal-account machines need no team lookup.
 *
 * A teammate the creator or a team admin shared the machine's chats with
 * (Leo, 2026-10-31: "we can't simply block always") is `owner` too, while the
 * grant stands and they are still on the member list. A grant never counts on
 * a personal-account machine (cmux-platform machineAccess `start_chat`).
 *
 * A different caller, a missing team, a creator who left the team, or a member
 * list that was not read, failed or timed out gets `team`. A row with no usable
 * billing owner is null. Ids compare exactly. Computed per request, never stored.
 * This caller-specific answer does not change teammates' existing access or
 * the guest-wide kind returned by resolveVmGuestKind.
 */
export function vmKindForCaller(
  row: VmGuestKindRow,
  callerUserId: string,
  members?: VmTeamMemberLookup,
  options: VmKindForCallerOptions = {},
): VmGuestKind | null {
  if (!row.ownerTeamId.trim()) return null;
  if (callerUserId === "") return "team";
  // Exact ids, no trimming: a padded id is not the caller.
  if (row.userId !== callerUserId) {
    return options.chatGranted === true && vmAcceptsChatGrants(row)
      && members !== undefined && callerIsMember(members, callerUserId) ? "owner" : "team";
  }
  if (row.ownerTeamId === callerUserId) return "owner";
  return members !== undefined && callerIsMember(members, callerUserId) ? "owner" : "team";
}

/**
 * True when vmKindForCaller's answer depends on the owner team's member list:
 * a machine the caller created on a Stack team, or one shared with the caller.
 * Every other row is answered without asking Stack.
 */
export function vmKindForCallerNeedsMembers(
  row: VmGuestKindRow,
  callerUserId: string,
  options: VmKindForCallerOptions = {},
): boolean {
  if (row.ownerTeamId.trim() === "" || callerUserId === "") return false;
  if (row.userId !== callerUserId) return options.chatGranted === true && vmAcceptsChatGrants(row);
  return row.ownerTeamId !== callerUserId;
}

/** True when a chat grant could make `callerUserId` this machine's `owner`, so it is worth reading. */
export function vmKindForCallerMayUseChatGrant(row: VmGuestKindRow, callerUserId: string): boolean {
  return callerUserId !== "" && row.userId !== callerUserId && vmAcceptsChatGrants(row);
}

/**
 * True for a machine whose chats can be shared: one on a Stack team. A
 * personal-account machine (or a row with no billing owner) never is.
 */
export function vmAcceptsChatGrants(row: VmGuestKindRow): boolean {
  return row.ownerTeamId.trim() !== "" && !vmIsOnPersonalAccount(row);
}

function callerIsMember(lookup: VmTeamMemberLookup, callerUserId: string): boolean {
  if ("error" in lookup || lookup.memberIds === null) return false;
  return lookup.memberIds.includes(callerUserId);
}
