import { sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import type { CoderouterAccountAccess } from "./accountAccess";
type Transaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

/** Grant a newly imported credential to this VM's pool in the insert transaction. */
export async function grantVmImportedAccount(
  tx: Transaction,
  teamId: string,
  accountId: string,
  family: "native" | "claude",
  access?: CoderouterAccountAccess,
): Promise<void> {
  if (!access || access.kind !== "vm") return;
  const column = family === "native" ? sql`account_id` : sql`claude_account_id`;
  const result: unknown = await tx.execute(sql`
    insert into coderouter_pool_accounts (team_id, pool_id, ${column}, granted_by_user_id)
    select owner_team_id, coderouter_pool_id, ${accountId}::uuid, user_id
    from cloud_vms
    where id = ${access.vmId}::uuid and owner_team_id = ${teamId}
      and coderouter_pool_id = ${access.poolId}::uuid
      and status in ('provisioning', 'running', 'paused')
    on conflict (pool_id, ${column}) do update set pool_id = excluded.pool_id
    returning pool_id
  `);
  const rows = Array.isArray(result) ? result : (result as { rows?: unknown[] })?.rows;
  if (!rows?.length) throw new Error("VM account scope changed during import");
}
