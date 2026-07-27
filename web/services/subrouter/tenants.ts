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

export async function getTenantForTeam(
  db: CloudDb,
  teamId: string,
  options: {
    readonly env?: SubrouterRuntimeEnv;
    readonly tenantKeySecret?: string;
  } = {},
): Promise<SubrouterTenantAccess | null> {
  const config = subrouterRuntimeConfig(options.env);
  const tenantKeySecret = options.tenantKeySecret ?? config?.tenantKeySecret;
  if (!tenantKeySecret) {
    throw new SubrouterNotConfiguredError();
  }

  const [existing] = await db
    .select({
      tenantId: subrouterTenants.tenantId,
      encryptedTenantKey: subrouterTenants.encryptedTenantKey,
    })
    .from(subrouterTenants)
    .where(eq(subrouterTenants.teamId, teamId))
    .limit(1);

  if (!existing) return null;

  return {
    tenantId: existing.tenantId,
    tenantKey: decryptTenantKey(existing.encryptedTenantKey, tenantKeySecret),
  };
}

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

    encryptTenantKey("subrouter-tenant-key-secret-probe", tenantKeySecret);
    const tenant = await client.createTenant({ name: normalizedTeamName });

    try {
      const encryptedTenantKey = encryptTenantKey(tenant.key, tenantKeySecret);
      const now = new Date();
      await tx.insert(subrouterTenants).values({
        teamId,
        tenantId: tenant.id,
        tenantName: tenant.name,
        encryptedTenantKey,
        createdAt: now,
        updatedAt: now,
      });
    } catch (err) {
      await revokeTenantBestEffort(client, tenant.id);
      throw err;
    }

    return {
      tenantId: tenant.id,
      tenantKey: tenant.key,
    };
  });
}

async function revokeTenantBestEffort(client: SubrouterClient, tenantId: string): Promise<void> {
  // The upstream tenant was already provisioned; revoke it (best effort)
  // so a failed local persistence step does not leave an orphaned tenant behind.
  try {
    await client.revokeTenant(tenantId);
  } catch {
    // Ignore revoke failures: the original persistence/encryption error is actionable.
  }
}
