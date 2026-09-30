import { sql, type SQL } from "drizzle-orm";

/** A human can use shared accounts and their own private imports. A machine
 * gets only its assigned pool, never its creator's personal account access.
 * A chatmux machine (chatmuxVmToken.ts) has no pool: it gets exactly the
 * accounts its team shares. A `crk_` API key is a team credential: in an
 * organization it gets only shared accounts, never its creator's private
 * imports. In a personal scope (team id = user id) it keeps the owner's
 * private imports, which are private by default. */
export type CoderouterAccountAccess =
  | { readonly kind: "user"; readonly userId: string }
  | { readonly kind: "api-key"; readonly apiKeyId: string; readonly teamId: string; readonly personal: boolean }
  | { readonly kind: "vm"; readonly vmId: string; readonly poolId: string | null; readonly creatorUserId: string }
  | { readonly kind: "team-machine"; readonly teamId: string; readonly machineId: string };

export function accountAccessForIdentity(identity: {
  readonly stackUserId: string;
  readonly vmId: string | null;
  readonly poolId?: string | null;
  readonly teamId?: string;
  readonly apiKeyId?: string | null;
  readonly machine?: "chatmux";
}): CoderouterAccountAccess {
  if (identity.machine === "chatmux") {
    return { kind: "team-machine", teamId: identity.teamId ?? "", machineId: identity.vmId ?? "" };
  }
  if (identity.vmId !== null) {
    return { kind: "vm", vmId: identity.vmId, poolId: identity.poolId ?? null, creatorUserId: identity.stackUserId };
  }
  if (identity.apiKeyId) {
    const teamId = identity.teamId ?? "";
    return { kind: "api-key", apiKeyId: identity.apiKeyId, teamId, personal: teamId !== "" && teamId === identity.stackUserId };
  }
  return { kind: "user", userId: identity.stackUserId };
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
  if (access.kind === "api-key") {
    if (!access.teamId) return sql`false`;
    // A personal scope's id is its owner's user id, so `created_by = team`
    // admits exactly the owner's private imports and nobody else's.
    return access.personal
      ? sql`(${account.teamId} = ${access.teamId} and (${account.visibility} = 'team' or ${account.createdBy} = ${access.teamId}))`
      : sql`(${account.teamId} = ${access.teamId} and ${account.visibility} = 'team')`;
  }
  if (access.kind === "team-machine") {
    // Only what the machine's own team shares; an empty team id matches nothing.
    if (!access.teamId) return sql`false`;
    return sql`(${account.visibility} = 'team' and ${account.teamId} = ${access.teamId})`;
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

/** Used before changing or deleting an account. A machine sees its whole
 * pool, but code running on it acts for its creator only: it may change or
 * remove the accounts its creator imported, never a teammate's shared
 * credentials. Every other caller mutates what it can read. */
export function accountMutationPredicate(
  account: { id: SQL; teamId: SQL; visibility: SQL; createdBy: SQL },
  family: "native" | "claude",
  access?: CoderouterAccountAccess,
): SQL {
  const readable = accountAccessPredicate(account, family, access);
  if (access?.kind !== "vm") return readable;
  return sql`(${readable} and ${account.createdBy} = ${access.creatorUserId})`;
}

/** The caller's session key is not a security namespace. */
export function scopedSessionKey(key: string | null, access?: CoderouterAccountAccess): string | null {
  if (!key || !access) return key;
  if (access.kind === "team-machine") return JSON.stringify(["team-machine", access.machineId, key]);
  // Per key, so a key never reuses a session its creator's own login bound.
  if (access.kind === "api-key") return JSON.stringify(["api-key", access.apiKeyId, key]);
  return JSON.stringify(access.kind === "vm"
    ? ["vm", access.vmId, access.poolId, key]
    : ["user", access.userId, key]);
}
