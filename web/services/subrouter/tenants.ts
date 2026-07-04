import { eq, sql } from "drizzle-orm";
import type { cloudDb } from "../../db/client";
import { subrouterTenants } from "../../db/schema";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  SubrouterNotConfiguredError,
  type SubrouterClient,
  type SubrouterRuntimeEnv,
} from "./client";
import { decryptTenantKey, encryptTenantKey } from "./crypto";

type CloudDb = ReturnType<typeof cloudDb>;

export type SubrouterTenantAccess = {
  readonly tenantId: string;
  readonly tenantKey: string;
};

export async function getOrCreateTenantForTeam(
  db: CloudDb,
  teamId: string,
  teamName: string,
  options: {
    readonly client?: SubrouterClient;
    readonly env?: SubrouterRuntimeEnv;
    readonly tenantKeySecret?: string;
  } = {},
): Promise<SubrouterTenantAccess> {
  const config = subrouterRuntimeConfig(options.env);
  const tenantKeySecret = options.tenantKeySecret ?? config?.tenantKeySecret;
  const client = options.client ?? (config
    ? createSubrouterClient({
        baseUrl: config.baseUrl,
        adminToken: config.adminToken,
      })
    : null);
  if (!tenantKeySecret || !client) {
    throw new SubrouterNotConfiguredError();
  }

  const normalizedTeamName = teamName.trim() || teamId;

  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${teamId}, 8))`);

    const [existing] = await tx
      .select({
        tenantId: subrouterTenants.tenantId,
        encryptedTenantKey: subrouterTenants.encryptedTenantKey,
      })
      .from(subrouterTenants)
      .where(eq(subrouterTenants.teamId, teamId))
      .limit(1);

    if (existing) {
      return {
        tenantId: existing.tenantId,
        tenantKey: decryptTenantKey(existing.encryptedTenantKey, tenantKeySecret),
      };
    }

    const tenant = await client.createTenant({ name: normalizedTeamName });
    const encryptedTenantKey = encryptTenantKey(tenant.key, tenantKeySecret);
    const now = new Date();

    try {
      await tx.insert(subrouterTenants).values({
        teamId,
        tenantId: tenant.id,
        tenantName: tenant.name,
        encryptedTenantKey,
        createdAt: now,
        updatedAt: now,
      });
    } catch (err) {
      // The upstream tenant was already provisioned; revoke it (best effort)
      // so a failed insert does not leave an orphaned tenant behind.
      try {
        await client.revokeTenant(tenant.id);
      } catch {
        // Ignore revoke failures: the original insert error is the actionable one.
      }
      throw err;
    }

    return {
      tenantId: tenant.id,
      tenantKey: tenant.key,
    };
  });
}
