import { sql, type SQL } from "drizzle-orm";

/** A human can use shared accounts and their own private imports. A machine
 * gets only its assigned pool, never its creator's personal account access. */
export type CoderouterAccountAccess =
  | { readonly kind: "user"; readonly userId: string }
  | { readonly kind: "vm"; readonly vmId: string; readonly poolId: string | null };

export function accountAccessForIdentity(identity: {
  readonly stackUserId: string;
  readonly vmId: string | null;
  readonly poolId?: string | null;
}): CoderouterAccountAccess {
  return identity.vmId === null
    ? { kind: "user", userId: identity.stackUserId }
    : { kind: "vm", vmId: identity.vmId, poolId: identity.poolId ?? null };
}

/** Used before listing, selection, stickiness reuse, and credential reads.
 * Callers still apply their team predicate. Membership and visibility are
 * rechecked in SQL so a cached session cannot restore a revoked grant. */
export function accountAccessPredicate(
  account: { id: SQL; teamId: SQL; visibility: SQL; createdBy: SQL },
  family: "native" | "claude",
  access?: CoderouterAccountAccess,
): SQL {
  // Internal administration and maintenance reads deliberately have no actor.
  if (!access) return sql`true`;
  if (access.kind === "user") {
    return sql`(${account.visibility} = 'team' or ${account.createdBy} = ${access.userId})`;
  }
  if (access.poolId === null) return sql`false`;
  // Personal scopes use the user id as their team id. Their owner’s private
  // accounts are intentionally usable by personal VMs, still behind the same
  // pool and VM-team checks. An organization VM never inherits this access.
  const membershipId = family === "native" ? sql`grant_row.account_id` : sql`grant_row.claude_account_id`;
  return sql`(
    (${account.visibility} = 'team' or ${account.createdBy} = ${account.teamId})
    and exists (
      select 1 from coderouter_pool_accounts grant_row
      join cloud_vms vm on vm.id = ${access.vmId}::uuid
      where grant_row.pool_id = ${access.poolId}::uuid
        and grant_row.pool_id = vm.coderouter_pool_id
        and grant_row.team_id = vm.owner_team_id
        and grant_row.team_id = ${account.teamId}
        and ${membershipId} = ${account.id}
        and vm.status in ('provisioning', 'running', 'paused')
    )
  )`;
}

/** The caller's session key is not a security namespace. */
export function scopedSessionKey(key: string | null, access?: CoderouterAccountAccess): string | null {
  if (!key || !access) return key;
  return JSON.stringify(access.kind === "vm"
    ? ["vm", access.vmId, access.poolId, key]
    : ["user", access.userId, key]);
}
