import { randomUUID } from "node:crypto";
import {
  findAccountByProviderIdentity,
  listAccounts,
  upsertAccountMetadata,
  withVaultLease,
} from "./repository";
import { putVaultCredential } from "./vault";
import type { CodeRouterCredential } from "./types";

export async function addAccount(
  teamId: string,
  credential: CodeRouterCredential,
): Promise<{ accountId: string; alreadyExists: boolean }> {
  return await withVaultLease(teamId, async () => {
    const existing = await findAccountByProviderIdentity(
      teamId,
      credential.provider,
      credential.accountId,
    );
    if (existing?.state === "active" || existing?.state === "refreshing") {
      return { accountId: existing.id, alreadyExists: true };
    }

    const accountId = existing?.id ?? randomUUID();
    const revision = await putVaultCredential(
      teamId,
      accountId,
      credential,
      existing?.vaultRevision,
    );
    await upsertAccountMetadata({
      teamId,
      accountId,
      credential,
      vaultRevision: revision,
    });
    return { accountId, alreadyExists: false };
  });
}

export { listAccounts };

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
