import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, gt, inArray, isNotNull, isNull, lt, lte, notInArray, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
  AccountDeletionMutationBlockedError,
  accountDeletionAdvisoryLockKey,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";
import { reportCoderouterFailure } from "./observability";
import {
  coderouterAccounts,
  coderouterCredentials,
  coderouterHandoffLeases,
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
export const CODEROUTER_HANDOFF_LEASE_TTL_MS = 2 * 60 * 1_000;
const CODEROUTER_HANDOFF_LEASE_BYTES = 32;
const CODEROUTER_HANDOFF_LEASE_SUFFIX_LENGTH = 43;
const MAX_HANDOFF_PRINCIPAL_ID_LENGTH = 200;
const CODEROUTER_HANDOFF_LEASE_PATTERN = new RegExp(
  `^crh_[A-Za-z0-9_-]{${CODEROUTER_HANDOFF_LEASE_SUFFIX_LENGTH}}$`,
);
const HANDOFF_LEASE_RETENTION_MS = 10 * 60 * 1_000;
const HANDOFF_LEASE_CLEANUP_BATCH_SIZE = 100;
const HANDOFF_LOCK_NAMESPACE = "coderouter-handoff";
const VAULT_LEASE_MS = 30_000;
const REFRESH_LEASE_MS = 30_000;
export type CodeRouterHandoffTransaction = Parameters<
  Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]
>[0];

export class CodeRouterHandoffEntitlementDenied extends Error {
  readonly _tag = "CodeRouterHandoffEntitlementDenied";
}

export class CodeRouterLeaseBusy extends Error {
  readonly _tag = "CodeRouterLeaseBusy";
}

export class CodeRouterCredentialRace extends Error {
  readonly _tag = "CodeRouterCredentialRace";
}

export function routeTokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

/**
 * Hashes the bearer value before it crosses the database boundary. Keep this
 * separate from routeTokenHash so callers cannot accidentally persist a
 * handoff value while adding a new repository operation.
 */
export function handoffLeaseHash(lease: string): string {
  return createHash("sha256").update(lease, "utf8").digest("hex");
}

function handoffLockKey(scope: "team" | "user", id: string): string {
  const digest = createHash("sha256").update(id, "utf8").digest("hex");
  return `${HANDOFF_LOCK_NAMESPACE}:${scope}:${digest}`;
}

async function lockHandoffUser(
  tx: CodeRouterHandoffTransaction,
  stackUserId: string,
): Promise<void> {
  await tx.execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${handoffLockKey("user", stackUserId)}, 0))`,
  );
}

async function lockHandoffPrincipal(
  tx: CodeRouterHandoffTransaction,
  teamId: string,
  stackUserId: string,
): Promise<void> {
  // Every operation that can create or invalidate authority acquires the
  // team lock first, then the user lock. Keeping this order avoids deadlocks
  // between team-scoped and user-scoped billing revocations.
  await lockHandoffTeam(tx, teamId);
  await lockHandoffUser(tx, stackUserId);
}

async function lockHandoffTeam(
  tx: CodeRouterHandoffTransaction,
  teamId: string,
): Promise<void> {
  await tx.execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${handoffLockKey("team", teamId)}, 0))`,
  );
}

/**
 * Account deletion and handoff operations use the account-deletion lock first,
 * then team and user handoff locks. Keeping invalidation in this transaction
 * makes the tombstone/authority boundary atomic: a mint or exchange cannot
 * insert or claim a lease after deletion has won the user lock.
 */
export async function invalidateCoderouterHandoffAuthority(
  tx: CodeRouterHandoffTransaction,
  input: {
    readonly stackUserId: string;
    readonly teamIds?: readonly string[];
  },
  now = new Date(),
): Promise<void> {
  const teamIds = [...new Set(input.teamIds ?? [])]
    .filter((teamId) => boundedHandoffPrincipalId(teamId))
    .sort();
  await tx.execute(
    sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.stackUserId)}, 0))`,
  );
  for (const teamId of teamIds) {
    await lockHandoffTeam(tx, teamId);
  }
  await lockHandoffUser(tx, input.stackUserId);

  const leaseAuthority = teamIds.length > 0
    ? or(
      eq(coderouterHandoffLeases.stackUserId, input.stackUserId),
      inArray(coderouterHandoffLeases.teamId, teamIds),
    )
    : eq(coderouterHandoffLeases.stackUserId, input.stackUserId);
  const routeAuthority = teamIds.length > 0
    ? or(
      eq(coderouterRouteTokens.stackUserId, input.stackUserId),
      inArray(coderouterRouteTokens.teamId, teamIds),
    )
    : eq(coderouterRouteTokens.stackUserId, input.stackUserId);
  await tx
    .update(coderouterHandoffLeases)
    .set({ consumedAt: now })
    .where(and(leaseAuthority, isNull(coderouterHandoffLeases.consumedAt)));
  await tx
    .update(coderouterRouteTokens)
    .set({ revokedAt: now })
    .where(and(routeAuthority, isNull(coderouterRouteTokens.revokedAt)));
}

export function isValidCoderouterHandoffLease(lease: string): boolean {
  return CODEROUTER_HANDOFF_LEASE_PATTERN.test(lease);
}

function newRouteToken(now: Date): { token: string; expiresAt: Date } {
  const token = `crt_${randomBytes(32).toString("base64url")}`;
  return {
    token,
    expiresAt: new Date(now.getTime() + ROUTE_TOKEN_LIFETIME_MS),
  };
}

export async function issueRouteToken(
  teamId: string,
  stackUserId: string,
  label = "cli",
): Promise<{ token: string; expiresAt: Date }> {
  const issued = newRouteToken(new Date());
  await cloudDb().insert(coderouterRouteTokens).values({
    teamId,
    stackUserId,
    tokenHash: routeTokenHash(issued.token),
    label,
    expiresAt: issued.expiresAt,
  });
  return issued;
}

export async function issueCoderouterHandoffLease(
  teamId: string,
  stackUserId: string,
  now = new Date(),
  authorize?: CodeRouterHandoffAuthorizer,
): Promise<{ lease: string; expiresAt: Date }> {
  if (!boundedHandoffPrincipalId(teamId) || !boundedHandoffPrincipalId(stackUserId)) {
    throw new Error("invalid CodeRouter handoff principal");
  }
  const lease = `crh_${
    randomBytes(CODEROUTER_HANDOFF_LEASE_BYTES).toString("base64url")
  }`;
  const expiresAt = new Date(now.getTime() + CODEROUTER_HANDOFF_LEASE_TTL_MS);
  const db = cloudDb();
  // Cleanup is deliberately isolated from issuance. PostgreSQL aborts the
  // surrounding transaction after a failed DELETE; catching that exception
  // would not make a subsequent INSERT usable.
  const cleanupBefore = new Date(
    now.getTime() - HANDOFF_LEASE_RETENTION_MS,
  ).toISOString();
  try {
    await db.transaction(async (tx) => {
      await tx.execute(sql`
        delete from "coderouter_handoff_leases"
        where "id" in (
          select "id"
          from "coderouter_handoff_leases"
          where "expires_at" < ${cleanupBefore}::timestamptz
          order by "expires_at" asc
          limit ${HANDOFF_LEASE_CLEANUP_BATCH_SIZE}
          for update skip locked
        )
      `);
    });
  } catch (error) {
    // Expired rows are harmless; leave them for the next mint or scheduled
    // database maintenance rather than failing closed on cleanup alone.
    try {
      reportCoderouterFailure("rds", error, {
        operation: "cleanup_handoff_leases",
      });
    } catch {
      // Observability is also best-effort; issuance must remain independent.
    }
  }

  await db.transaction(async (tx) => {
    // Serialize minting with billing revocation on the same principal lock.
    // The entitlement read happens before this repository call, but the
    // transaction-bound authorizer below rechecks it after this lock. This
    // makes the entitlement decision and lease insert one authority check.
    await assertAccountDeletionUserMutationAllowed(tx, stackUserId);
    await lockHandoffPrincipal(tx, teamId, stackUserId);
    if (authorize && !(await authorize({ teamId, stackUserId }, tx))) {
      throw new CodeRouterHandoffEntitlementDenied(
        "CodeRouter entitlement is no longer active",
      );
    }
    await tx.insert(coderouterHandoffLeases).values({
      teamId,
      stackUserId,
      leaseHash: handoffLeaseHash(lease),
      expiresAt,
      createdAt: now,
    });
  });
  return { lease, expiresAt };
}

function boundedHandoffPrincipalId(value: string): boolean {
  return value.length > 0 &&
    value.length <= MAX_HANDOFF_PRINCIPAL_ID_LENGTH &&
    value === value.trim() &&
    !/[\u0000-\u001f\u007f]/.test(value);
}

export type CodeRouterHandoffIdentity = {
  readonly teamId?: string;
  readonly stackUserId?: string;
};

export type CodeRouterHandoffEntitlementDb = Pick<
  ReturnType<typeof cloudDb>,
  "select"
>;

export type CodeRouterHandoffAuthorizer = (
  identity: {
    readonly teamId: string;
    readonly stackUserId: string;
  },
  db: CodeRouterHandoffEntitlementDb,
) => Promise<boolean>;

/**
 * Claims a handoff row and inserts the existing route-token record in one
 * database transaction. PostgreSQL's conditional UPDATE serializes competing
 * claims; a failed token insert rolls the consumed marker back with the
 * transaction, so a transient database error never burns a valid lease. An
 * optional authorizer is evaluated against the stored principal immediately
 * before the claim, which lets hosted billing revalidate possession-only
 * exchanges without requiring Stack credentials.
 */
export async function exchangeCoderouterHandoffLease(
  lease: string,
  now = new Date(),
  expectedIdentity: CodeRouterHandoffIdentity = {},
  authorize?: CodeRouterHandoffAuthorizer,
): Promise<
  | {
    readonly teamId: string;
    readonly stackUserId: string;
    readonly token: string;
    readonly expiresAt: Date;
  }
  | null
> {
  if (!isValidCoderouterHandoffLease(lease)) return null;
  const hasExpectedTeam = expectedIdentity.teamId !== undefined;
  const hasExpectedUser = expectedIdentity.stackUserId !== undefined;
  if (
    (hasExpectedTeam &&
      !boundedHandoffPrincipalId(expectedIdentity.teamId!)) ||
    (hasExpectedUser &&
      !boundedHandoffPrincipalId(expectedIdentity.stackUserId!))
  ) {
    return null;
  }

  const leaseHash = handoffLeaseHash(lease);
  const predicates = [
    eq(coderouterHandoffLeases.leaseHash, leaseHash),
    gt(coderouterHandoffLeases.expiresAt, sql`now()`),
    isNull(coderouterHandoffLeases.consumedAt),
    ...(hasExpectedTeam
      ? [eq(coderouterHandoffLeases.teamId, expectedIdentity.teamId!)]
      : []),
    ...(hasExpectedUser
      ? [eq(coderouterHandoffLeases.stackUserId, expectedIdentity.stackUserId!)]
      : []),
  ];
  return await cloudDb().transaction(async (tx) => {
    const [candidate] = await tx
      .select({
        teamId: coderouterHandoffLeases.teamId,
        stackUserId: coderouterHandoffLeases.stackUserId,
      })
      .from(coderouterHandoffLeases)
      .where(and(...predicates))
      .limit(1);
    if (!candidate) return null;
    try {
      await assertAccountDeletionUserMutationAllowed(tx, candidate.stackUserId);
    } catch (error) {
      if (error instanceof AccountDeletionMutationBlockedError) return null;
      throw error;
    }
    await lockHandoffPrincipal(tx, candidate.teamId, candidate.stackUserId);
    if (authorize && !(await authorize(candidate, tx))) return null;

    const [claimed] = await tx
      .update(coderouterHandoffLeases)
      .set({ consumedAt: now })
      .where(and(
        ...predicates,
        gt(coderouterHandoffLeases.expiresAt, sql`now()`),
      ))
      .returning({
        teamId: coderouterHandoffLeases.teamId,
        stackUserId: coderouterHandoffLeases.stackUserId,
      });
    if (!claimed) return null;

    const issued = newRouteToken(now);
    await tx.insert(coderouterRouteTokens).values({
      teamId: claimed.teamId,
      stackUserId: claimed.stackUserId,
      tokenHash: routeTokenHash(issued.token),
      label: "native-handoff",
      expiresAt: issued.expiresAt,
    });
    return { ...claimed, ...issued };
  });
}

export async function revokeRouteTokensForUser(
  stackUserId: string,
  now = new Date(),
): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    // Lock the handoff authority before revoking route tokens. Exchange uses
    // the same order, so a billing revocation cannot race a lease claim and
    // leave a freshly inserted route token alive.
    // User-scoped billing revocation has no team selector; take the user
    // authority lock used by all user-scoped handoff operations.
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(stackUserId)}, 0))`,
    );
    await lockHandoffUser(tx, stackUserId);
    await tx
      .update(coderouterHandoffLeases)
      .set({ consumedAt: now })
      .where(and(
        eq(coderouterHandoffLeases.stackUserId, stackUserId),
        isNull(coderouterHandoffLeases.consumedAt),
      ));
    await tx
      .update(coderouterRouteTokens)
      .set({ revokedAt: now })
      .where(and(
        eq(coderouterRouteTokens.stackUserId, stackUserId),
        isNull(coderouterRouteTokens.revokedAt),
      ));
  });
}

export async function revokeRouteTokensForTeam(
  teamId: string,
  now = new Date(),
): Promise<void> {
  await cloudDb().transaction(async (tx) => {
    // Team billing revocation and handoff mint/exchange share this authority
    // lock. User deletion additionally takes the account-deletion lock.
    await lockHandoffTeam(tx, teamId);
    await tx
      .update(coderouterHandoffLeases)
      .set({ consumedAt: now })
      .where(and(
        eq(coderouterHandoffLeases.teamId, teamId),
        isNull(coderouterHandoffLeases.consumedAt),
      ));
    await tx
      .update(coderouterRouteTokens)
      .set({ revokedAt: now })
      .where(and(
        eq(coderouterRouteTokens.teamId, teamId),
        isNull(coderouterRouteTokens.revokedAt),
      ));
  });
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
    // Removing the last provider account revokes the team's handoff
    // authority. Serialize that decision with mint/exchange before checking
    // for remaining accounts; otherwise an exchange that already selected a
    // lease could claim it after this transaction's revocation update.
    await lockHandoffTeam(tx, input.teamId);
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
        .update(coderouterHandoffLeases)
        .set({ consumedAt: now })
        .where(and(
          eq(coderouterHandoffLeases.teamId, input.teamId),
          isNull(coderouterHandoffLeases.consumedAt),
        ));
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
