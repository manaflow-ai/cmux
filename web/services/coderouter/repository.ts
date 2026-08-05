import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, gt, isNull, lte, notInArray, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
  coderouterAccounts,
  coderouterRouteTokens,
  coderouterVaultLeases,
} from "../../db/schema";
import type {
  CodeRouterAccountSummary,
  CodeRouterCredential,
  CodeRouterProvider,
} from "./types";

const ROUTE_TOKEN_LIFETIME_MS = 30 * 24 * 60 * 60 * 1_000;
const VAULT_LEASE_MS = 30_000;
const REFRESH_LEASE_MS = 30_000;

export class CodeRouterLeaseBusy extends Error {
  readonly _tag = "CodeRouterLeaseBusy";
}

export function routeTokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export async function issueRouteToken(
  teamId: string,
  label = "cli",
): Promise<{ token: string; expiresAt: Date }> {
  const token = `crt_${randomBytes(32).toString("base64url")}`;
  const expiresAt = new Date(Date.now() + ROUTE_TOKEN_LIFETIME_MS);
  await cloudDb().insert(coderouterRouteTokens).values({
    teamId,
    tokenHash: routeTokenHash(token),
    label,
    expiresAt,
  });
  return { token, expiresAt };
}

export async function authenticateRouteToken(
  token: string,
  now = new Date(),
): Promise<{ teamId: string } | null> {
  if (!/^crt_[A-Za-z0-9_-]{40,}$/.test(token)) return null;
  const [row] = await cloudDb()
    .select({ id: coderouterRouteTokens.id, teamId: coderouterRouteTokens.teamId })
    .from(coderouterRouteTokens)
    .where(and(
      eq(coderouterRouteTokens.tokenHash, routeTokenHash(token)),
      gt(coderouterRouteTokens.expiresAt, now),
      isNull(coderouterRouteTokens.revokedAt),
    ))
    .limit(1);
  if (!row) return null;
  await cloudDb()
    .update(coderouterRouteTokens)
    .set({ lastUsedAt: now })
    .where(eq(coderouterRouteTokens.id, row.id));
  return { teamId: row.teamId };
}

export async function revokeRouteToken(
  teamId: string,
  token: string,
  now = new Date(),
): Promise<void> {
  if (!/^crt_[A-Za-z0-9_-]{40,}$/.test(token)) return;
  await cloudDb()
    .update(coderouterRouteTokens)
    .set({ revokedAt: now })
    .where(and(
      eq(coderouterRouteTokens.teamId, teamId),
      eq(coderouterRouteTokens.tokenHash, routeTokenHash(token)),
      isNull(coderouterRouteTokens.revokedAt),
    ));
}

export async function listAccounts(
  teamId: string,
): Promise<readonly CodeRouterAccountSummary[]> {
  return await cloudDb()
    .select({
      id: coderouterAccounts.id,
      provider: coderouterAccounts.provider,
      providerAccountId: coderouterAccounts.providerAccountId,
      label: coderouterAccounts.label,
      state: coderouterAccounts.state,
      credentialExpiresAt: coderouterAccounts.credentialExpiresAt,
      lastFailureCode: coderouterAccounts.lastFailureCode,
    })
    .from(coderouterAccounts)
    .where(eq(coderouterAccounts.teamId, teamId))
    .then((rows) => rows.map((row) => ({
      ...row,
      credentialExpiresAt: row.credentialExpiresAt?.toISOString() ?? null,
    })));
}

export async function upsertAccountMetadata(input: {
  readonly teamId: string;
  readonly accountId: string;
  readonly credential: CodeRouterCredential;
  readonly vaultRevision: number;
}): Promise<void> {
  const providerAccountId = input.credential.accountId;
  const label = input.credential.email ||
    (input.credential.provider === "opencode-go"
      ? input.credential.orgName
      : undefined) ||
    providerAccountId;
  await cloudDb()
    .insert(coderouterAccounts)
    .values({
      id: input.accountId,
      teamId: input.teamId,
      provider: input.credential.provider,
      providerAccountId,
      label,
      state: "active",
      vaultRevision: input.vaultRevision,
      credentialExpiresAt: new Date(input.credential.expiresAt),
      updatedAt: new Date(),
    })
    .onConflictDoUpdate({
      target: [
        coderouterAccounts.teamId,
        coderouterAccounts.provider,
        coderouterAccounts.providerAccountId,
      ],
      set: {
        label,
        state: "active",
        vaultRevision: input.vaultRevision,
        credentialExpiresAt: new Date(input.credential.expiresAt),
        lastFailureCode: null,
        updatedAt: new Date(),
      },
    });
}

export async function findAccountByProviderIdentity(
  teamId: string,
  provider: CodeRouterProvider,
  providerAccountId: string,
): Promise<{ id: string; state: string; vaultRevision: number } | null> {
  const [row] = await cloudDb()
    .select({
      id: coderouterAccounts.id,
      state: coderouterAccounts.state,
      vaultRevision: coderouterAccounts.vaultRevision,
    })
    .from(coderouterAccounts)
    .where(and(
      eq(coderouterAccounts.teamId, teamId),
      eq(coderouterAccounts.provider, provider),
      eq(coderouterAccounts.providerAccountId, providerAccountId),
    ))
    .limit(1);
  return row ?? null;
}

export async function selectAccountForRequest(
  teamId: string,
  provider: CodeRouterProvider,
  excludedAccountIds: readonly string[] = [],
): Promise<{
  id: string;
  vaultRevision: number;
  credentialExpiresAt: Date | null;
} | null> {
  const now = new Date();
  await cloudDb()
    .update(coderouterAccounts)
    .set({
      state: "active",
      refreshLeaseId: null,
      refreshLeaseExpiresAt: null,
      updatedAt: now,
    })
    .where(and(
      eq(coderouterAccounts.teamId, teamId),
      eq(coderouterAccounts.state, "refreshing"),
      lte(coderouterAccounts.refreshLeaseExpiresAt, now),
    ));
  const [row] = await cloudDb()
    .select({
      id: coderouterAccounts.id,
      vaultRevision: coderouterAccounts.vaultRevision,
      credentialExpiresAt: coderouterAccounts.credentialExpiresAt,
    })
    .from(coderouterAccounts)
    .where(and(
      eq(coderouterAccounts.teamId, teamId),
      eq(coderouterAccounts.provider, provider),
      eq(coderouterAccounts.state, "active"),
      or(
        isNull(coderouterAccounts.cooldownUntil),
        lte(coderouterAccounts.cooldownUntil, now),
      ),
      excludedAccountIds.length === 0
        ? sql`true`
        : notInArray(coderouterAccounts.id, [...excludedAccountIds]),
    ))
    .orderBy(sql`${coderouterAccounts.lastUsedAt} asc nulls first`, coderouterAccounts.createdAt)
    .limit(1);
  if (!row) return null;
  await cloudDb()
    .update(coderouterAccounts)
    .set({ lastUsedAt: new Date() })
    .where(eq(coderouterAccounts.id, row.id));
  return row;
}

export async function markAccountCooldown(
  accountId: string,
  durationMs: number,
): Promise<void> {
  const bounded = Math.min(Math.max(durationMs, 1_000), 7 * 24 * 60 * 60 * 1_000);
  await cloudDb()
    .update(coderouterAccounts)
    .set({
      cooldownUntil: new Date(Date.now() + bounded),
      lastFailureCode: "rate_limited",
      updatedAt: new Date(),
    })
    .where(eq(coderouterAccounts.id, accountId));
}

export async function claimRefreshLease(
  accountId: string,
  now = new Date(),
): Promise<string | null> {
  const leaseId = randomUUID();
  const [claimed] = await cloudDb()
    .update(coderouterAccounts)
    .set({
      state: "refreshing",
      refreshLeaseId: leaseId,
      refreshLeaseExpiresAt: new Date(now.getTime() + REFRESH_LEASE_MS),
      updatedAt: now,
    })
    .where(and(
      eq(coderouterAccounts.id, accountId),
      or(
        isNull(coderouterAccounts.refreshLeaseExpiresAt),
        lte(coderouterAccounts.refreshLeaseExpiresAt, now),
      ),
    ))
    .returning({ id: coderouterAccounts.id });
  return claimed ? leaseId : null;
}

export async function completeRefreshLease(input: {
  readonly accountId: string;
  readonly leaseId: string;
  readonly vaultRevision: number;
  readonly credentialExpiresAt: Date;
}): Promise<void> {
  await cloudDb()
    .update(coderouterAccounts)
    .set({
      state: "active",
      vaultRevision: input.vaultRevision,
      credentialExpiresAt: input.credentialExpiresAt,
      refreshLeaseId: null,
      refreshLeaseExpiresAt: null,
      lastFailureCode: null,
      updatedAt: new Date(),
    })
    .where(and(
      eq(coderouterAccounts.id, input.accountId),
      eq(coderouterAccounts.refreshLeaseId, input.leaseId),
    ));
}

export async function failRefreshLease(
  accountId: string,
  leaseId: string,
  terminal: boolean,
  code: string,
): Promise<void> {
  await cloudDb()
    .update(coderouterAccounts)
    .set({
      state: terminal ? "broken" : "active",
      refreshLeaseId: null,
      refreshLeaseExpiresAt: null,
      lastFailureCode: code.slice(0, 128),
      updatedAt: new Date(),
    })
    .where(and(
      eq(coderouterAccounts.id, accountId),
      eq(coderouterAccounts.refreshLeaseId, leaseId),
    ));
}

export async function withVaultLease<T>(
  teamId: string,
  operation: () => Promise<T>,
  now = () => new Date(),
): Promise<T> {
  const leaseId = randomUUID();
  const db = cloudDb();
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${"coderouter-vault:" + teamId}, 0))`,
    );
    const reservedAt = now();
    await tx
      .delete(coderouterVaultLeases)
      .where(and(
        eq(coderouterVaultLeases.teamId, teamId),
        lte(coderouterVaultLeases.expiresAt, reservedAt),
      ));
    const [active] = await tx
      .select({ leaseId: coderouterVaultLeases.leaseId })
      .from(coderouterVaultLeases)
      .where(eq(coderouterVaultLeases.teamId, teamId))
      .limit(1);
    if (active) throw new CodeRouterLeaseBusy("Stack vault is busy");
    await tx.insert(coderouterVaultLeases).values({
      teamId,
      leaseId,
      expiresAt: new Date(reservedAt.getTime() + VAULT_LEASE_MS),
      updatedAt: reservedAt,
    });
  });
  try {
    return await operation();
  } finally {
    await db
      .delete(coderouterVaultLeases)
      .where(and(
        eq(coderouterVaultLeases.teamId, teamId),
        eq(coderouterVaultLeases.leaseId, leaseId),
      ))
      .catch(() => undefined);
  }
}
