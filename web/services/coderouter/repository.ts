import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, gt, isNotNull, isNull, lt, lte, notInArray, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
  coderouterAccounts,
  coderouterCredentials,
  coderouterRouteTokens,
  coderouterVaultLeases,
} from "../../db/schema";
import type { EncryptedCredential } from "./encryption";
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

export class CodeRouterCredentialRace extends Error {
  readonly _tag = "CodeRouterCredentialRace";
}

export function routeTokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export async function issueRouteToken(
  teamId: string,
  stackUserId: string,
  label = "cli",
): Promise<{ token: string; expiresAt: Date }> {
  const token = `crt_${randomBytes(32).toString("base64url")}`;
  const expiresAt = new Date(Date.now() + ROUTE_TOKEN_LIFETIME_MS);
  await cloudDb().insert(coderouterRouteTokens).values({
    teamId,
    stackUserId,
    tokenHash: routeTokenHash(token),
    label,
    expiresAt,
  });
  return { token, expiresAt };
}

export async function revokeRouteTokensForUser(
  stackUserId: string,
  now = new Date(),
): Promise<void> {
  await cloudDb()
    .update(coderouterRouteTokens)
    .set({ revokedAt: now })
    .where(and(
      eq(coderouterRouteTokens.stackUserId, stackUserId),
      isNull(coderouterRouteTokens.revokedAt),
    ));
}

export async function revokeRouteTokensForTeam(
  teamId: string,
  now = new Date(),
): Promise<void> {
  await cloudDb()
    .update(coderouterRouteTokens)
    .set({ revokedAt: now })
    .where(and(
      eq(coderouterRouteTokens.teamId, teamId),
      isNull(coderouterRouteTokens.revokedAt),
    ));
}

export async function authenticateRouteToken(
  token: string,
  now = new Date(),
): Promise<{ teamId: string; stackUserId: string } | null> {
  if (!/^crt_[A-Za-z0-9_-]{40,}$/.test(token)) return null;
  const [row] = await cloudDb()
    .update(coderouterRouteTokens)
    .set({ lastUsedAt: now })
    .where(and(
      eq(coderouterRouteTokens.tokenHash, routeTokenHash(token)),
      isNotNull(coderouterRouteTokens.stackUserId),
      gt(coderouterRouteTokens.expiresAt, now),
      isNull(coderouterRouteTokens.revokedAt),
    ))
    .returning({
      teamId: coderouterRouteTokens.teamId,
      stackUserId: coderouterRouteTokens.stackUserId,
    });
  return row ?? null;
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

export async function deleteAccount(input: {
  readonly teamId: string;
  readonly accountId: string;
  readonly now?: Date;
}): Promise<{ removed: boolean; lastAccount: boolean }> {
  const now = input.now ?? new Date();
  return await cloudDb().transaction(async (tx) => {
    const [removed] = await tx
      .delete(coderouterAccounts)
      .where(and(
        eq(coderouterAccounts.id, input.accountId),
        eq(coderouterAccounts.teamId, input.teamId),
      ))
      .returning({ id: coderouterAccounts.id });
    if (!removed) return { removed: false, lastAccount: false };

    // coderouterCredentials is deleted by its account FK. If the workspace no
    // longer has an account, route tokens have no useful authority and should
    // not remain live.
    const [remaining] = await tx
      .select({ id: coderouterAccounts.id })
      .from(coderouterAccounts)
      .where(eq(coderouterAccounts.teamId, input.teamId))
      .limit(1);
    if (!remaining) {
      await tx
        .update(coderouterRouteTokens)
        .set({ revokedAt: now })
        .where(and(
          eq(coderouterRouteTokens.teamId, input.teamId),
          isNull(coderouterRouteTokens.revokedAt),
        ));
    }
    return { removed: true, lastAccount: !remaining };
  });
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

export async function listCoderouterTeamIds(): Promise<readonly string[]> {
  return await cloudDb()
    .selectDistinct({ teamId: coderouterAccounts.teamId })
    .from(coderouterAccounts)
    .then((rows) => rows.map((row) => row.teamId));
}

export async function listEncryptedCredentials(
  teamId: string,
): Promise<readonly EncryptedCredential[]> {
  return await cloudDb()
    .select({
      accountId: coderouterCredentials.accountId,
      teamId: coderouterCredentials.teamId,
      provider: coderouterCredentials.provider,
      credentialRevision: coderouterCredentials.credentialRevision,
      algorithm: coderouterCredentials.algorithm,
      ciphertext: coderouterCredentials.ciphertext,
      nonce: coderouterCredentials.nonce,
      authTag: coderouterCredentials.authTag,
      encryptedDataKey: coderouterCredentials.encryptedDataKey,
      kmsKeyId: coderouterCredentials.kmsKeyId,
    })
    .from(coderouterCredentials)
    .where(eq(coderouterCredentials.teamId, teamId))
    .then((rows) => rows.map(encryptedCredentialRow));
}

export async function encryptedCredentialForAccount(
  teamId: string,
  accountId: string,
): Promise<EncryptedCredential | null> {
  const [row] = await cloudDb()
    .select({
      accountId: coderouterCredentials.accountId,
      teamId: coderouterCredentials.teamId,
      provider: coderouterCredentials.provider,
      credentialRevision: coderouterCredentials.credentialRevision,
      algorithm: coderouterCredentials.algorithm,
      ciphertext: coderouterCredentials.ciphertext,
      nonce: coderouterCredentials.nonce,
      authTag: coderouterCredentials.authTag,
      encryptedDataKey: coderouterCredentials.encryptedDataKey,
      kmsKeyId: coderouterCredentials.kmsKeyId,
    })
    .from(coderouterCredentials)
    .where(and(
      eq(coderouterCredentials.teamId, teamId),
      eq(coderouterCredentials.accountId, accountId),
    ))
    .limit(1);
  return row ? encryptedCredentialRow(row) : null;
}

export async function insertAccountWithCredential(input: {
  readonly credential: CodeRouterCredential;
  readonly encrypted: EncryptedCredential;
}): Promise<boolean> {
  const db = cloudDb();
  return await db.transaction(async (tx) => {
    const label = credentialLabel(input.credential);
    const [inserted] = await tx
      .insert(coderouterAccounts)
      .values({
        id: input.encrypted.accountId,
        teamId: input.encrypted.teamId,
        provider: input.credential.provider,
        providerAccountId: input.credential.accountId,
        label,
        state: "active",
        vaultRevision: input.encrypted.credentialRevision,
        credentialExpiresAt: new Date(input.credential.expiresAt),
        updatedAt: new Date(),
      })
      .onConflictDoNothing({
        target: [
          coderouterAccounts.teamId,
          coderouterAccounts.provider,
          coderouterAccounts.providerAccountId,
        ],
      })
      .returning({ id: coderouterAccounts.id });
    if (!inserted) return false;
    await tx.insert(coderouterCredentials).values(encryptedValues(input.encrypted));
    return true;
  });
}

export async function replaceAccountCredential(input: {
  readonly credential: CodeRouterCredential;
  readonly encrypted: EncryptedCredential;
  readonly expectedRevision: number;
}): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    const [updatedCredential] = await tx
      .update(coderouterCredentials)
      .set({
        ...encryptedValues(input.encrypted),
        updatedAt: new Date(),
      })
      .where(and(
        eq(coderouterCredentials.accountId, input.encrypted.accountId),
        eq(coderouterCredentials.teamId, input.encrypted.teamId),
        eq(coderouterCredentials.credentialRevision, input.expectedRevision),
      ))
      .returning({ accountId: coderouterCredentials.accountId });
    if (!updatedCredential) {
      throw new CodeRouterCredentialRace("credential revision changed");
    }
    const [updatedAccount] = await tx
      .update(coderouterAccounts)
      .set({
        label: credentialLabel(input.credential),
        state: "active",
        vaultRevision: input.encrypted.credentialRevision,
        credentialExpiresAt: new Date(input.credential.expiresAt),
        refreshLeaseId: null,
        refreshLeaseExpiresAt: null,
        lastFailureCode: null,
        updatedAt: new Date(),
      })
      .where(and(
        eq(coderouterAccounts.id, input.encrypted.accountId),
        eq(coderouterAccounts.teamId, input.encrypted.teamId),
        eq(coderouterAccounts.vaultRevision, input.expectedRevision),
      ))
      .returning({ id: coderouterAccounts.id });
    if (!updatedAccount) {
      throw new CodeRouterCredentialRace("account revision changed");
    }
  });
}

export async function importEncryptedCredential(input: {
  readonly credential: CodeRouterCredential;
  readonly encrypted: EncryptedCredential;
}): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    const [inserted] = await tx
      .insert(coderouterCredentials)
      .values(encryptedValues(input.encrypted))
      .onConflictDoNothing({
        target: coderouterCredentials.accountId,
      })
      .returning({ accountId: coderouterCredentials.accountId });
    if (!inserted) {
      await tx
        .update(coderouterCredentials)
        .set({
          ...encryptedValues(input.encrypted),
          updatedAt: new Date(),
        })
        .where(and(
          eq(coderouterCredentials.accountId, input.encrypted.accountId),
          lt(
            coderouterCredentials.credentialRevision,
            input.encrypted.credentialRevision,
          ),
        ));
    }
    await tx
      .update(coderouterAccounts)
      .set({
        label: credentialLabel(input.credential),
        vaultRevision: input.encrypted.credentialRevision,
        credentialExpiresAt: new Date(input.credential.expiresAt),
        updatedAt: new Date(),
      })
      .where(and(
        eq(coderouterAccounts.id, input.encrypted.accountId),
        eq(coderouterAccounts.teamId, input.encrypted.teamId),
        lt(coderouterAccounts.vaultRevision, input.encrypted.credentialRevision),
      ));
  });
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
  readonly expectedRevision: number;
  readonly credential: CodeRouterCredential;
  readonly encrypted: EncryptedCredential;
}): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    const [updatedCredential] = await tx
      .update(coderouterCredentials)
      .set({
        ...encryptedValues(input.encrypted),
        updatedAt: new Date(),
      })
      .where(and(
        eq(coderouterCredentials.accountId, input.accountId),
        eq(coderouterCredentials.credentialRevision, input.expectedRevision),
      ))
      .returning({ accountId: coderouterCredentials.accountId });
    if (!updatedCredential) {
      throw new CodeRouterCredentialRace("credential refresh lost revision race");
    }
    const [completed] = await tx
      .update(coderouterAccounts)
      .set({
        state: "active",
        vaultRevision: input.encrypted.credentialRevision,
        credentialExpiresAt: new Date(input.credential.expiresAt),
        refreshLeaseId: null,
        refreshLeaseExpiresAt: null,
        lastFailureCode: null,
        updatedAt: new Date(),
      })
      .where(and(
        eq(coderouterAccounts.id, input.accountId),
        eq(coderouterAccounts.refreshLeaseId, input.leaseId),
        eq(coderouterAccounts.vaultRevision, input.expectedRevision),
      ))
      .returning({ id: coderouterAccounts.id });
    if (!completed) {
      throw new CodeRouterCredentialRace("credential refresh lost lease");
    }
  });
}

export async function releaseRefreshLease(
  accountId: string,
  leaseId: string,
): Promise<void> {
  await cloudDb()
    .update(coderouterAccounts)
    .set({
      state: "active",
      refreshLeaseId: null,
      refreshLeaseExpiresAt: null,
      lastFailureCode: null,
      updatedAt: new Date(),
    })
    .where(and(
      eq(coderouterAccounts.id, accountId),
      eq(coderouterAccounts.refreshLeaseId, leaseId),
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
    if (active) throw new CodeRouterLeaseBusy("coderouter vault is busy");
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

function credentialLabel(credential: CodeRouterCredential): string {
  return credential.email ||
    (credential.provider === "opencode-go" ? credential.orgName : undefined) ||
    credential.accountId;
}

function encryptedValues(encrypted: EncryptedCredential) {
  return {
    accountId: encrypted.accountId,
    teamId: encrypted.teamId,
    provider: encrypted.provider,
    credentialRevision: encrypted.credentialRevision,
    algorithm: encrypted.algorithm,
    ciphertext: encrypted.ciphertext,
    nonce: encrypted.nonce,
    authTag: encrypted.authTag,
    encryptedDataKey: encrypted.encryptedDataKey,
    kmsKeyId: encrypted.kmsKeyId,
  };
}

function encryptedCredentialRow(row: {
  accountId: string;
  teamId: string;
  provider: CodeRouterProvider;
  credentialRevision: number;
  algorithm: string;
  ciphertext: string;
  nonce: string;
  authTag: string;
  encryptedDataKey: string;
  kmsKeyId: string;
}): EncryptedCredential {
  if (row.algorithm !== "aes-256-gcm") {
    throw new Error("unsupported coderouter credential encryption algorithm");
  }
  return {
    ...row,
    algorithm: "aes-256-gcm",
  };
}
