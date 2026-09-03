import { createHash, randomBytes, randomUUID } from "node:crypto";
import { and, eq, gt, isNotNull, isNull, lt, lte, or, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import {
  coderouterAccounts,
  coderouterCredentials,
  coderouterRouteTokens,
  coderouterSessionAccounts,
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

const ROUTE_TOKEN_PATTERN = /^crt_[A-Za-z0-9_-]{40,}$/;

export type RouteTokenPrincipal = {
  readonly teamId: string;
  readonly stackUserId: string;
  /** Cloud VM the token is bound to, or null for an unbound (CLI) token. */
  readonly vmId: string | null;
};

export async function issueRouteToken(
  teamId: string,
  stackUserId: string,
  label = "cli",
  options?: { readonly vmId?: string },
): Promise<{ token: string; expiresAt: Date }> {
  const token = `crt_${randomBytes(32).toString("base64url")}`;
  const expiresAt = new Date(Date.now() + ROUTE_TOKEN_LIFETIME_MS);
  await cloudDb().insert(coderouterRouteTokens).values({
    teamId,
    stackUserId,
    tokenHash: routeTokenHash(token),
    label,
    vmId: options?.vmId ?? null,
    expiresAt,
  });
  return { token, expiresAt };
}

/**
 * Binds a live, still-unbound token of this team to one Cloud VM. Binding is
 * one-way: a token already bound (to any VM) is left untouched and reported
 * as not bound, so a later caller cannot move a credential between machines.
 */
export async function bindRouteTokenToVm(
  teamId: string,
  token: string,
  vmId: string,
): Promise<boolean> {
  if (!ROUTE_TOKEN_PATTERN.test(token)) return false;
  const [row] = await cloudDb()
    .update(coderouterRouteTokens)
    .set({ vmId })
    .where(and(
      eq(coderouterRouteTokens.teamId, teamId),
      eq(coderouterRouteTokens.tokenHash, routeTokenHash(token)),
      isNull(coderouterRouteTokens.vmId),
      isNull(coderouterRouteTokens.revokedAt),
    ))
    .returning({ id: coderouterRouteTokens.id });
  return row !== undefined;
}

export async function revokeRouteTokensForVm(
  vmId: string,
  now = new Date(),
): Promise<void> {
  await cloudDb()
    .update(coderouterRouteTokens)
    .set({ revokedAt: now })
    .where(and(
      eq(coderouterRouteTokens.vmId, vmId),
      isNull(coderouterRouteTokens.revokedAt),
    ));
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
): Promise<RouteTokenPrincipal | null> {
  if (!ROUTE_TOKEN_PATTERN.test(token)) return null;
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
      vmId: coderouterRouteTokens.vmId,
    });
  return row ?? null;
}

export async function revokeRouteToken(
  teamId: string,
  token: string,
  now = new Date(),
): Promise<void> {
  if (!ROUTE_TOKEN_PATTERN.test(token)) return;
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
  const [rows, sessionCounts] = await Promise.all([
    cloudDb()
      .select({
        id: coderouterAccounts.id,
        provider: coderouterAccounts.provider,
        providerAccountId: coderouterAccounts.providerAccountId,
        label: coderouterAccounts.label,
        state: coderouterAccounts.state,
        credentialExpiresAt: coderouterAccounts.credentialExpiresAt,
        lastFailureCode: coderouterAccounts.lastFailureCode,
        cooldownUntil: coderouterAccounts.cooldownUntil,
      })
      .from(coderouterAccounts)
      .where(eq(coderouterAccounts.teamId, teamId)),
    countActiveSessionsByAccount(teamId),
  ]);
  return rows.map((row) => ({
    ...row,
    credentialExpiresAt: row.credentialExpiresAt?.toISOString() ?? null,
    cooldownUntil: row.cooldownUntil?.toISOString() ?? null,
    activeSessions: sessionCounts.get(row.id) ?? 0,
  }));
}

/**
 * Sessions bound per account with traffic inside the load window. Display
 * only: a failure here must never take the status endpoint down.
 */
async function countActiveSessionsByAccount(
  teamId: string,
): Promise<ReadonlyMap<string, number>> {
  try {
    const rows = await cloudDb()
      .select({
        accountId: coderouterSessionAccounts.accountId,
        sessions: sql<number>`count(*)::int`,
      })
      .from(coderouterSessionAccounts)
      .where(and(
        eq(coderouterSessionAccounts.teamId, teamId),
        gt(
          coderouterSessionAccounts.lastSeenAt,
          sql`now() - interval '${sql.raw(SESSION_BINDING_LOAD_WINDOW)}'`,
        ),
      ))
      .groupBy(coderouterSessionAccounts.accountId);
    return new Map(rows.map((row) => [row.accountId, Number(row.sessions)]));
  } catch {
    return new Map();
  }
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

export type RoutedAccount = {
  id: string;
  vaultRevision: number;
  credentialExpiresAt: Date | null;
};

export type StickyRoutedAccount = RoutedAccount & {
  /** True when the session's existing account binding was honored. */
  sticky: boolean;
};

/** Bindings older than this stop counting toward an account's session load. */
const SESSION_BINDING_LOAD_WINDOW = "6 hours";
/** Bindings idle longer than this are pruned opportunistically. */
const SESSION_BINDING_RETENTION = "7 days";

async function sweepExpiredRefreshLeases(teamId: string): Promise<void> {
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
}

/**
 * Returns the session's bound account when that account is still usable.
 * Bumps the binding's last-seen time and the account's last-used time so
 * new-session placement steers away from accounts with live traffic.
 */
export async function findSessionAccount(
  teamId: string,
  provider: CodeRouterProvider,
  sessionKey: string,
  excludedAccountIds: readonly string[] = [],
): Promise<RoutedAccount | null> {
  let result: unknown;
  try {
    result = await findSessionAccountStatement(
      teamId,
      provider,
      sessionKey,
      excludedAccountIds,
    );
  } catch (error) {
    // The session table's migration has not been applied yet. Route without
    // stickiness rather than failing the request.
    if (isMissingSessionTableError(error)) return null;
    throw error;
  }
  const [row] = databaseRows(result);
  if (!row) return null;
  await cloudDb()
    .update(coderouterAccounts)
    .set({ lastUsedAt: new Date() })
    .where(eq(coderouterAccounts.id, String(row.id)));
  return routedAccountRow(row);
}

async function findSessionAccountStatement(
  teamId: string,
  provider: CodeRouterProvider,
  sessionKey: string,
  excludedAccountIds: readonly string[],
): Promise<unknown> {
  return await cloudDb().execute(sql`
    update "coderouter_session_accounts" as binding
    set "last_seen_at" = now()
    from "coderouter_accounts" as account
    where binding."team_id" = ${teamId}
      and binding."provider" = ${provider}
      and binding."session_key" = ${sessionKey}
      and account."id" = binding."account_id"
      -- 'refreshing' is a healthy account with a credential refresh in
      -- flight (seconds). Moving the session would discard its prompt
      -- cache for no reason, so the binding stays usable.
      and account."state" in ('active', 'refreshing')
      and (account."cooldown_until" is null or account."cooldown_until" <= now())
      ${accountExclusion(sql`account."id"`, excludedAccountIds)}
    returning
      account."id" as "id",
      account."vault_revision" as "vaultRevision",
      account."credential_expires_at" as "credentialExpiresAt"
  `);
}

/**
 * Atomically claims the best placement candidate for a new session or an
 * unbound request. One statement performs read, pick, and write:
 * FOR UPDATE SKIP LOCKED makes concurrent claims take different accounts
 * instead of all reading the same snapshot and herding onto one account
 * (the TypeScript port of subrouter PR #228's placement spread). Ordering
 * prefers the fewest recently-active bound sessions, then least-recently-used.
 */
export async function claimAccountForPlacement(
  teamId: string,
  provider: CodeRouterProvider,
  excludedAccountIds: readonly string[] = [],
): Promise<RoutedAccount | null> {
  try {
    return await claimWithOrdering(teamId, provider, excludedAccountIds, true);
  } catch (error) {
    // The session table's migration has not been applied yet. Claim without
    // the session-load ordering term rather than failing the request.
    if (!isMissingSessionTableError(error)) throw error;
    return await claimWithOrdering(teamId, provider, excludedAccountIds, false);
  }
}

async function claimWithOrdering(
  teamId: string,
  provider: CodeRouterProvider,
  excludedAccountIds: readonly string[],
  withSessionLoad: boolean,
): Promise<RoutedAccount | null> {
  // First pass skips rows other placements hold locked, so overlapping claims
  // fan out across different accounts instead of herding onto one.
  const spread = await claimStatement(
    teamId,
    provider,
    excludedAccountIds,
    true,
    withSessionLoad,
  );
  if (spread) return spread;
  // Every usable account was locked by a concurrent claim (or none exists).
  // Fall back to a blocking claim: colliding with another placement is far
  // better than telling the caller no account is available.
  return await claimStatement(
    teamId,
    provider,
    excludedAccountIds,
    false,
    withSessionLoad,
  );
}

async function claimStatement(
  teamId: string,
  provider: CodeRouterProvider,
  excludedAccountIds: readonly string[],
  skipLocked: boolean,
  withSessionLoad: boolean,
): Promise<RoutedAccount | null> {
  const result = await cloudDb().execute(sql`
    with candidate as (
      select account."id"
      from "coderouter_accounts" as account
      where account."team_id" = ${teamId}
        and account."provider" = ${provider}
        and account."state" = 'active'
        and (account."cooldown_until" is null or account."cooldown_until" <= now())
        ${accountExclusion(sql`account."id"`, excludedAccountIds)}
      order by
        ${withSessionLoad
          ? sql`(
              select count(*)
              from "coderouter_session_accounts" as binding
              where binding."account_id" = account."id"
                and binding."last_seen_at" > now() - interval '${sql.raw(SESSION_BINDING_LOAD_WINDOW)}'
            ) asc,`
          : sql``}
        account."last_used_at" asc nulls first,
        account."created_at" asc
      limit 1
      ${skipLocked ? sql.raw("for update of account skip locked") : sql``}
    )
    update "coderouter_accounts" as claimed
    set "last_used_at" = now(), "updated_at" = now()
    from candidate
    where claimed."id" = candidate."id"
    returning
      claimed."id" as "id",
      claimed."vault_revision" as "vaultRevision",
      claimed."credential_expires_at" as "credentialExpiresAt"
  `);
  const [row] = databaseRows(result);
  return row ? routedAccountRow(row) : null;
}

/** Pins a session to an account. Last write wins on a same-session race. */
export async function bindSessionAccount(
  teamId: string,
  provider: CodeRouterProvider,
  sessionKey: string,
  accountId: string,
): Promise<void> {
  const db = cloudDb();
  try {
    await db
      .insert(coderouterSessionAccounts)
      .values({ teamId, provider, sessionKey, accountId })
      .onConflictDoUpdate({
        target: [
          coderouterSessionAccounts.teamId,
          coderouterSessionAccounts.provider,
          coderouterSessionAccounts.sessionKey,
        ],
        set: { accountId, lastSeenAt: new Date() },
      });
    await db.execute(sql`
      delete from "coderouter_session_accounts"
      where "team_id" = ${teamId}
        and "last_seen_at" < now() - interval '${sql.raw(SESSION_BINDING_RETENTION)}'
    `);
  } catch (error) {
    // The session table's migration has not been applied yet. Skip the pin
    // rather than failing the request; routing degrades to the legacy
    // per-request behavior until the migration lands.
    if (isMissingSessionTableError(error)) return;
    throw error;
  }
}

/** Postgres undefined_table (42P01), possibly wrapped by the ORM. */
function isMissingSessionTableError(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; depth < 5 && current; depth++) {
    if (
      typeof current === "object" &&
      "code" in current &&
      (current as { code?: unknown }).code === "42P01"
    ) {
      return true;
    }
    current = typeof current === "object" && current !== null && "cause" in current
      ? (current as { cause?: unknown }).cause
      : undefined;
  }
  return false;
}

export type SessionAccountSelectorDependencies = {
  readonly sweepLeases: typeof sweepExpiredRefreshLeases;
  readonly findBound: typeof findSessionAccount;
  readonly claim: typeof claimAccountForPlacement;
  readonly bind: typeof bindSessionAccount;
};

/**
 * Session-sticky account selection.
 *
 * A bound session keeps riding its account while that account is usable, so
 * the provider's prompt cache stays warm. A session moves only when its
 * account is broken, cooling down, removed, or already attempted this request
 * (the move-worthiness gate from subrouter PR #228, reduced to the binary
 * usability signal this schema has). Placement of a new or moving session
 * spreads across the least-loaded usable accounts.
 */
export function createSessionAccountSelector(
  dependencies: SessionAccountSelectorDependencies,
): (input: {
  teamId: string;
  provider: CodeRouterProvider;
  sessionKey: string | null;
  excludedAccountIds?: readonly string[];
}) => Promise<StickyRoutedAccount | null> {
  return async (input) => {
    const excluded = input.excludedAccountIds ?? [];
    await dependencies.sweepLeases(input.teamId);
    if (input.sessionKey) {
      const bound = await dependencies.findBound(
        input.teamId,
        input.provider,
        input.sessionKey,
        excluded,
      );
      if (bound) return { ...bound, sticky: true };
    }
    const placed = await dependencies.claim(
      input.teamId,
      input.provider,
      excluded,
    );
    if (!placed) return null;
    if (input.sessionKey) {
      await dependencies.bind(
        input.teamId,
        input.provider,
        input.sessionKey,
        placed.id,
      );
    }
    return { ...placed, sticky: false };
  };
}

export const selectAccountForSession = createSessionAccountSelector({
  sweepLeases: sweepExpiredRefreshLeases,
  findBound: findSessionAccount,
  claim: claimAccountForPlacement,
  bind: bindSessionAccount,
});

export async function selectAccountForRequest(
  teamId: string,
  provider: CodeRouterProvider,
  excludedAccountIds: readonly string[] = [],
): Promise<RoutedAccount | null> {
  await sweepExpiredRefreshLeases(teamId);
  return await claimAccountForPlacement(teamId, provider, excludedAccountIds);
}

function accountExclusion(
  column: ReturnType<typeof sql>,
  excludedAccountIds: readonly string[],
) {
  if (excludedAccountIds.length === 0) return sql``;
  return sql` and ${column} not in (${
    sql.join(excludedAccountIds.map((id) => sql`${id}`), sql`, `)
  })`;
}

function routedAccountRow(row: Record<string, unknown>): RoutedAccount {
  return {
    id: String(row.id),
    vaultRevision: Number(row.vaultRevision),
    credentialExpiresAt: row.credentialExpiresAt instanceof Date
      ? row.credentialExpiresAt
      : row.credentialExpiresAt
      ? new Date(String(row.credentialExpiresAt))
      : null,
  };
}

function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as readonly Record<string, unknown>[];
  const rows = (result as { readonly rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as readonly Record<string, unknown>[] : [];
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
