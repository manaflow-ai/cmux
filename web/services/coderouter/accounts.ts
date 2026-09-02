import { randomUUID } from "node:crypto";
import {
  findAccountByProviderIdentity,
  deleteAccount,
  insertAccountWithCredential,
  listAccounts,
  replaceAccountCredential,
  withVaultLease,
} from "./repository";
import { encryptCredential } from "./encryption";
import type { CodeRouterCredential } from "./types";
import { deleteVaultCredential } from "./vault";
import { reportCoderouterFailure } from "./observability";

type AddAccountOptions = {
  /**
   * Replace a healthy existing account's credential instead of leaving it
   * untouched — for callers that hand over freshly rotated tokens for an
   * account the vault already knows (the connected-account mirror).
   */
  readonly refreshExisting?: boolean;
};

export type AddAccountResult = {
  accountId: string;
  /**
   * The vault already served this account when the call arrived. False for a
   * fresh insert and for the repair of an expired/broken account, which the
   * caller reports as a new connection (201) either way.
   */
  alreadyExists: boolean;
  /** An existing credential was replaced at the caller's request. */
  refreshed: boolean;
};

export function createAccountAdder(dependencies: {
  readonly find: typeof findAccountByProviderIdentity;
  readonly encrypt: typeof encryptCredential;
  readonly insert: typeof insertAccountWithCredential;
  readonly replace: typeof replaceAccountCredential;
}): (
  teamId: string,
  credential: CodeRouterCredential,
  options?: AddAccountOptions,
) => Promise<AddAccountResult> {
  return async (teamId, credential, options = {}) => {
    const existing = await dependencies.find(
      teamId,
      credential.provider,
      credential.accountId,
    );
    const healthy = existing?.state === "active" || existing?.state === "refreshing";
    if (existing && healthy && !options.refreshExisting) {
      return { accountId: existing.id, alreadyExists: true, refreshed: false };
    }

    const accountId = existing?.id ?? randomUUID();
    const expectedRevision = existing?.vaultRevision ?? 0;
    const encrypted = await dependencies.encrypt({
      teamId,
      accountId,
      provider: credential.provider,
      credentialRevision: expectedRevision + 1,
      credential,
    });
    if (!existing) {
      const inserted = await dependencies.insert({
        credential,
        encrypted,
      });
      if (!inserted) {
        const raced = await dependencies.find(
          teamId,
          credential.provider,
          credential.accountId,
        );
        if (raced) return { accountId: raced.id, alreadyExists: true, refreshed: false };
        throw new Error("coderouter account insert lost a uniqueness race");
      }
      return { accountId, alreadyExists: false, refreshed: false };
    }
    await dependencies.replace({
      credential,
      encrypted,
      expectedRevision,
    });
    // Replacing a healthy credential is a refresh of a connected account;
    // replacing an expired or broken one is a repair that reconnects it.
    return {
      accountId,
      alreadyExists: healthy,
      refreshed: options.refreshExisting === true,
    };
  };
}

export const addAccount = createAccountAdder({
  find: findAccountByProviderIdentity,
  encrypt: encryptCredential,
  insert: insertAccountWithCredential,
  replace: replaceAccountCredential,
});

export { listAccounts };

type RemoveAccountResult = {
  removed: boolean;
  lastAccount: boolean;
  legacyCleanupPending: boolean;
};

export function createAccountRemover(dependencies: {
  readonly deleteRuntime: typeof deleteAccount;
  readonly deleteLegacy: typeof deleteVaultCredential;
  readonly withLease: typeof withVaultLease;
  readonly report: typeof reportCoderouterFailure;
}): (teamId: string, accountId: string) => Promise<RemoveAccountResult> {
  return async (teamId, accountId) => {
    const result = await dependencies.deleteRuntime({ teamId, accountId });
    if (!result.removed) return { ...result, legacyCleanupPending: false };
    try {
      // Temporary rollback copy only. This call disappears after the migration
      // cleanup window; failure cannot restore runtime access to the credential.
      await dependencies.withLease(
        teamId,
        async () => await dependencies.deleteLegacy(teamId, accountId),
      );
      return { ...result, legacyCleanupPending: false };
    } catch (error) {
      dependencies.report("legacy_cleanup", error);
      return { ...result, legacyCleanupPending: true };
    }
  };
}

export const removeAccount = createAccountRemover({
  deleteRuntime: deleteAccount,
  deleteLegacy: deleteVaultCredential,
  withLease: withVaultLease,
  report: reportCoderouterFailure,
});

export function parseCredential(value: unknown): CodeRouterCredential | null {
  if (!isRecord(value)) return null;
  const provider = value.provider;
  const accessToken = boundedString(value.accessToken, 32_768);
  const refreshToken = boundedString(value.refreshToken, 32_768);
  const accountId = boundedString(value.accountId, 512);
  const email = boundedString(value.email, 320);
  const expiresAt = value.expiresAt;
  if (
    !accessToken ||
    !refreshToken ||
    !accountId ||
    !email ||
    typeof expiresAt !== "number" ||
    !Number.isFinite(expiresAt) ||
    expiresAt <= Date.now() - 24 * 60 * 60 * 1_000
  ) {
    return null;
  }
  if (provider === "codex") {
    const idToken = boundedString(value.idToken, 32_768);
    return idToken
      ? {
        provider,
        accessToken,
        refreshToken,
        idToken,
        accountId,
        email,
        expiresAt,
      }
      : null;
  }
  if (provider === "opencode-go") {
    const orgId = optionalBoundedString(value.orgId, 512);
    const orgName = optionalBoundedString(value.orgName, 512);
    return {
      provider,
      accessToken,
      refreshToken,
      accountId,
      email,
      expiresAt,
      ...(orgId ? { orgId } : {}),
      ...(orgName ? { orgName } : {}),
    };
  }
  if (provider === "claude") {
    const subscriptionType = optionalBoundedString(value.subscriptionType, 128);
    return {
      provider,
      accessToken,
      refreshToken,
      accountId,
      email,
      expiresAt,
      ...(subscriptionType ? { subscriptionType } : {}),
    };
  }
  return null;
}

function boundedString(value: unknown, max: number): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= max
    ? value
    : null;
}

function optionalBoundedString(value: unknown, max: number): string | null {
  return value === undefined || value === null ? null : boundedString(value, max);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
