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
// - `owner`: the machine belongs to its creator's personal billing account
//   (owner_team_id is the creator's user id, the synthetic personal team).
// - `team`: every real team account, even while the creator is its only current
//   member. Membership is not a revocation receipt: a departed member's VPC
//   tunnel/publication/session can outlive the directory update.
// - unknown (null): the row has no usable billing owner.
import type { VmPrincipalRow } from "./vmPrincipalContract";

export type VmGuestKind = "owner" | "team";

/** The row facts the kind depends on. */
export type VmGuestKindRow = Pick<VmPrincipalRow, "userId" | "ownerTeamId">;

/** True when the machine belongs to its creator's own account, with no Stack team to ask. */
export function vmIsOnPersonalAccount(row: VmGuestKindRow): boolean {
  const owner = row.ownerTeamId.trim();
  return owner !== "" && owner === row.userId.trim();
}

/** The machine's kind from its durable billing scope, never transient membership. */
export function resolveVmGuestKind(row: VmGuestKindRow): VmGuestKind | null {
  if (vmIsOnPersonalAccount(row)) return "owner";
  const teamId = row.ownerTeamId.trim();
  if (!teamId) return null;
  return "team";
}
