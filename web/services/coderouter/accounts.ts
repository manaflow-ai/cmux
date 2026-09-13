import { createHash, randomUUID } from "node:crypto";
import {
  findAccountByProviderIdentity,
  deleteAccount,
  insertAccountWithCredential,
  listAccounts,
  replaceAccountCredential,
  withVaultLease,
  bindCodexOwnerIdentity,
  encryptedCredentialForAccount,
  updateAccountLabel,
} from "./repository";
import { decryptCredential, encryptCredential, type CredentialKeyService } from "./encryption";
import {
  CODEROUTER_API_KEY_PROVIDERS,
  type CodeRouterApiKeyProvider,
  type CodeRouterCredential,
} from "./types";
import { deleteVaultCredential } from "./vault";
import { reportCoderouterFailure } from "./observability";
import { providerIdentityKey, withCodexOwner } from "./codexIdentity";
import { verifyCodexCredential } from "./codexSignature";

export async function addAccount(
  teamId: string,
  credential: CodeRouterCredential,
  keys?: CredentialKeyService,
  verify: typeof verifyCodexCredential = verifyCodexCredential,
): Promise<{ accountId: string; alreadyExists: boolean }> {
  if (credential.provider === "codex") {
    await verify(credential);
    credential = withCodexOwner(credential);
    await upgradeLegacyCodexIdentity(teamId, credential.accountId, keys);
  }
  const existing = await findAccountByProviderIdentity(
    teamId,
    credential.provider,
    providerIdentityKey(credential),
  );
  if (existing?.state === "active" || existing?.state === "refreshing") {
    await updateAccountLabel(teamId, existing.id, credential);
    return { accountId: existing.id, alreadyExists: true };
  }

  const accountId = existing?.id ?? randomUUID();
  const expectedRevision = existing?.vaultRevision ?? 0;
  const encrypted = await encryptCredential({
    teamId,
    accountId,
    provider: credential.provider,
    credentialRevision: expectedRevision + 1,
    credential,
    keys,
  });
  if (!existing) {
    const inserted = await insertAccountWithCredential({
      credential,
      encrypted,
    });
    if (!inserted) {
      const raced = await findAccountByProviderIdentity(
        teamId,
        credential.provider,
        providerIdentityKey(credential),
      );
      if (raced) return { accountId: raced.id, alreadyExists: true };
      throw new Error("coderouter account insert lost a uniqueness race");
    }
  } else {
    await replaceAccountCredential({
      credential,
      encrypted,
      expectedRevision,
    });
  }
  return { accountId, alreadyExists: false };
}

/** Legacy workspace-only rows are adopted from their own encrypted credentials. */
export async function upgradeLegacyCodexIdentity(teamId: string, workspaceId: string, keys?: CredentialKeyService): Promise<void> {
  const legacy = await findAccountByProviderIdentity(teamId, "codex", workspaceId);
  if (!legacy) return;
  const encrypted = await encryptedCredentialForAccount(teamId, legacy.id);
  if (!encrypted) throw new Error("legacy Codex credential is unavailable");
  const credential = await decryptCredential(encrypted, keys);
  if (credential.provider !== "codex" || credential.accountId !== workspaceId) throw new Error("legacy Codex identity does not match its record");
  const migrated = await bindCodexOwnerIdentity({
    teamId, accountId: legacy.id, expectedKey: workspaceId,
    expectedRevision: encrypted.credentialRevision, credential: withCodexOwner(credential),
  });
  if (!migrated && await findAccountByProviderIdentity(teamId, "codex", workspaceId)) {
    throw new Error("legacy Codex credential changed during identity upgrade; retry");
  }
}

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

const MAX_API_KEY_LENGTH = 512;
const MAX_LABEL_LENGTH = 120;
const API_KEY_PATTERN = /^[A-Za-z0-9._~+/=-]+$/;

export function parseCredential(value: unknown): CodeRouterCredential | null {
  if (!isRecord(value)) return null;
  const provider = value.provider;
  if (isApiKeyProviderName(provider)) return parseApiKeyCredential(provider, value);
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
    if (!idToken) return null;
    try {
      return withCodexOwner({
        provider,
        accessToken,
        refreshToken,
        idToken,
        accountId,
        email,
        expiresAt,
        ...(value.userId !== undefined ? { userId: boundedString(value.userId, 512) ?? "" } : {}),
      });
    } catch { return null; }
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
  return null;
}

function isApiKeyProviderName(value: unknown): value is CodeRouterApiKeyProvider {
  return typeof value === "string" &&
    (CODEROUTER_API_KEY_PROVIDERS as readonly string[]).includes(value);
}

/**
 * `{ provider, apiKey, label? }` from the dashboard or `cr add`. The key is
 * validated as one printable token; the fingerprint becomes the provider
 * account id, so re-adding the same key updates the existing row.
 */
function parseApiKeyCredential(
  provider: CodeRouterApiKeyProvider,
  value: Record<string, unknown>,
): CodeRouterCredential | null {
  const apiKey = typeof value.apiKey === "string" ? value.apiKey.trim() : "";
  if (apiKey.length < 16 || apiKey.length > MAX_API_KEY_LENGTH || !API_KEY_PATTERN.test(apiKey)) {
    return null;
  }
  const rawLabel = value.label;
  if (rawLabel !== undefined && rawLabel !== null && typeof rawLabel !== "string") return null;
  const label = typeof rawLabel === "string" ? rawLabel.trim() : "";
  if (label.length > MAX_LABEL_LENGTH) return null;
  return {
    provider,
    apiKey,
    accountId: apiKeyFingerprint(provider, apiKey),
    label,
  };
}

export function apiKeyFingerprint(provider: CodeRouterApiKeyProvider, apiKey: string): string {
  return createHash("sha256").update(`${provider}\n${apiKey}`).digest("hex").slice(0, 24);
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
